// Garmin style file (TYP): the colours and widths that a map is drawn with.
// Ported from QMapShack's map/garmin/CGarminTyp.cpp, and the polygon draw order from map/CMapIMG.cpp
// (Copyright 2008-2014 Oliver Eichler, GPL-3.0-or-later).
// The day styles of lines (colour, border, width, bitmap pattern), of polygons (colour or bitmap pattern), the
// polygon draw order, and the day icons and labels of points are read. Night colours are skipped.

import BaseCampCore
import Foundation

public enum GarminTypError: Error {
    case notTyp
}

/// The style of one map: how each line and polygon type is drawn, and the order polygons are drawn in.
public struct GarminTypStyle: Sendable {
    public struct RGB: Hashable, Sendable {
        public let red: UInt8
        public let green: UInt8
        public let blue: UInt8
    }

    /// A one-bit picture, 32 pixels wide, repeated along a line or across an area. Set pixels take the foreground
    /// colour; the others take the background colour, or stay transparent when there is none.
    public struct Bitmap: Hashable, Sendable {
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

    /// How a point's name is written: QMapShack's `label_type_e`.
    public enum LabelSize: Int, Sendable {
        case standard = 0, none, small, normal, large
    }

    /// A point's icon and label. The icon is `width` by `height` pixels, row by row from the top, four bytes per
    /// pixel: red, green, blue and alpha (not premultiplied).
    public struct Point: Equatable, Sendable {
        public let width: Int
        public let height: Int
        public let rgba: [UInt8]
        public var labelSize: LabelSize = .standard
        /// The day colour of the label, when the style sets one.
        public var labelColour: RGB?
        /// What the type is, in the style's first language (for example "Summit"), when the style names it.
        public var name: String?
    }

    /// Point style by feature type: type byte then subtype byte (0x6616 for a summit). Version 2 types are
    /// 0x10000 + (type << 8) + subtype.
    public private(set) var points: [Int: Point] = [:]
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
        points = Self.points(bytes)
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

    /// The point section, following QMapShack's `CGarminTyp::parsePoint`. Point types keep their subtype in the low
    /// byte. Icons with more than 8 bits per pixel are skipped, as QMapShack does.
    private static func points(_ bytes: [UInt8]) -> [Int: Point] {
        let dataOffset = Int(u32(bytes, 0x17))
        let array = Array(bytes[0x33..<0x3d])
        let offset = Int(u32(array, 0))
        let modulo = Int(u16(array, 4))
        let size = Int(u32(array, 6))
        guard (3...5).contains(modulo), size % modulo == 0 else { return [:] }
        let encoding = textEncoding(codepage: Int(u16(bytes, 0x15)))
        var result: [Int: Point] = [:]
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
            let subtype = typeWord & 0x1f
            let type = typeWord & 0x2000 != 0
                ? 0x10000 | ((packed & 0x7ff) << 8) | subtype
                : ((packed & 0x7ff) << 8) + subtype
            var reader = Reader(bytes: bytes, position: dataOffset + recordOffset)
            if let point = point(&reader, encoding: encoding) {
                result[type] = point
            }
        }
        return result
    }

    private static func point(_ reader: inout Reader, encoding: String.Encoding) -> Point? {
        guard let flags = reader.byte(), let width = reader.byte().map(Int.init), let height = reader.byte().map(Int.init),
              var colourCount = reader.byte().map(Int.init), let colourKind = reader.byte(),
              let bpp = bitsPerPixel(colours: colourCount, kind: colourKind), width > 0, height > 0 else { return nil }
        if colourKind == 0x20 || colourKind == 0x00, colourCount == 0, bpp >= 16 {
            colourCount = width * height
        }
        guard bpp < 16, let palette = colourTable(&reader, count: colourCount, size: 1 << bpp, alpha: colourKind == 0x20),
              let indices = pixels(&reader, width: width, height: height, bpp: bpp) else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for (pixel, index) in indices.enumerated() where index < palette.count {
            let colour = palette[index]
            rgba[pixel * 4] = colour.red
            rgba[pixel * 4 + 1] = colour.green
            rgba[pixel * 4 + 2] = colour.blue
            rgba[pixel * 4 + 3] = colour.alpha
        }
        var point = Point(width: width, height: height, rgba: rgba)

        // The night icon: its own colours and pixels (3), or its own colours only (2). Read past it.
        let night = flags & 0x03
        if night == 0x03 || night == 0x02 {
            guard let count = reader.byte().map(Int.init), let kind = reader.byte(),
                  let nightBpp = bitsPerPixel(colours: count, kind: kind),
                  colourTable(&reader, count: count, size: 1 << nightBpp, alpha: kind == 0x20) != nil else { return point }
            if night == 0x03, pixels(&reader, width: width, height: height, bpp: nightBpp) == nil {
                return point
            }
        }

        if flags & 0x04 != 0 {
            point.name = localizedName(&reader, encoding: encoding)
        }
        if flags & 0x08 != 0, let text = reader.byte() {
            point.labelSize = LabelSize(rawValue: Int(text & 0x07)) ?? .standard
            if text & 0x08 != 0, let blue = reader.byte(), let green = reader.byte(), let red = reader.byte() {
                point.labelColour = RGB(red: red, green: green, blue: blue)
            }
        }
        return point
    }

    /// QMapShack's `decodeBppAndBytes`: the bits per pixel for a colour count and colour kind (0x00 plain, 0x10
    /// with a transparent colour, 0x20 with alpha).
    private static func bitsPerPixel(colours: Int, kind: UInt8) -> Int? {
        switch kind {
        case 0x00:
            if colours < 3 { return colours }
            if colours == 3 { return 2 }
            if colours < 16 { return 4 }
            if colours < 256 { return 8 }
        case 0x10:
            if colours == 0 { return 1 }
            if colours < 3 { return 2 }
            if colours < 15 { return 4 }
            if colours < 256 { return 8 }
        case 0x20:
            if colours == 0 { return 16 }
            if colours < 3 { return colours }
            if colours < 4 { return 2 }
            if colours < 16 { return 4 }
            if colours < 256 { return 8 }
        default:
            break
        }
        return nil
    }

    private struct RGBA {
        let red, green, blue, alpha: UInt8
    }

    /// QMapShack's `decodeColorTable`: blue, green, red per colour; with alpha, 28 bits per colour (red, green and
    /// blue bytes, then 4 bits of transparency). Indices from `count` to `size` are transparent.
    private static func colourTable(_ reader: inout Reader, count: Int, size: Int, alpha: Bool) -> [RGBA]? {
        var colours: [RGBA] = []
        if alpha {
            var register: UInt32 = 0
            var bits: UInt32 = 0
            for _ in 0..<count {
                while bits < 28 {
                    guard let byte = reader.byte() else { return nil }
                    register = (register & ~(0xFF << bits)) | (UInt32(byte) << bits)
                    bits += 8
                }
                let transparency = UInt8((register >> 24) & 0x0F)
                colours.append(RGBA(
                    red: UInt8((register >> 16) & 0xFF), green: UInt8((register >> 8) & 0xFF), blue: UInt8(register & 0xFF),
                    alpha: (15 - transparency) * 17
                ))
                register >>= 28
                bits -= 28
            }
        } else {
            for _ in 0..<count {
                guard let blue = reader.byte(), let green = reader.byte(), let red = reader.byte() else { return nil }
                colours.append(RGBA(red: red, green: green, blue: blue, alpha: 255))
            }
        }
        while colours.count < size {
            colours.append(RGBA(red: 0, green: 0, blue: 0, alpha: 0))
        }
        return colours
    }

    /// QMapShack's `decodeBitmap`: each row starts on a byte; pixels are packed from the low bits up.
    private static func pixels(_ reader: inout Reader, width: Int, height: Int, bpp: Int) -> [Int]? {
        guard [1, 2, 4, 8].contains(bpp) else { return bpp == 0 ? Array(repeating: 0, count: width * height) : nil }
        let mask = (1 << bpp) - 1
        var result: [Int] = []
        result.reserveCapacity(width * height)
        for _ in 0..<height {
            var x = 0
            while x < width {
                guard let byte = reader.byte() else { return nil }
                var value = Int(byte)
                for _ in 0..<(8 / bpp) where x < width {
                    result.append(value & mask)
                    value >>= bpp
                    x += 1
                }
            }
        }
        return result
    }

    /// The first of a record's names (one per language), following QMapShack's `parsePoint`.
    private static func localizedName(_ reader: inout Reader, encoding: String.Encoding) -> String? {
        guard let first = reader.byte() else { return nil }
        var length = Int(first)
        var step = 1
        if first & 0x01 == 0 {
            guard let second = reader.byte() else { return nil }
            step = 2
            length |= Int(second) << 8
        }
        length -= step
        var names: [String] = []
        while length > 0 {
            guard reader.byte() != nil else { break } // language code
            length -= 2 * step
            var text: [UInt8] = []
            while length > 0 {
                guard let byte = reader.byte() else { break }
                length -= 2 * step
                if byte == 0 { break }
                text.append(byte)
            }
            if let name = String(bytes: text, encoding: encoding), !name.isEmpty {
                names.append(name)
            }
        }
        return names.first
    }

    private static func textEncoding(codepage: Int) -> String.Encoding {
        switch codepage {
        case 65001: return .utf8
        case 1250: return .windowsCP1250
        case 1251: return .windowsCP1251
        case 1253: return .windowsCP1253
        case 1254: return .windowsCP1254
        default: return .windowsCP1252
        }
    }

    /// Reads bytes in turn, and gives nil past the end instead of trapping.
    private struct Reader {
        let bytes: [UInt8]
        var position: Int

        mutating func byte() -> UInt8? {
            guard position >= 0, position < bytes.count else { return nil }
            defer { position += 1 }
            return bytes[position]
        }
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
