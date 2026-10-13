// Copyright (C) 2026 the BaseCamp Clone contributors
//
// This file is part of BaseCamp Clone, free software under the GNU General Public License
// version 3 or later. See LICENSE.
//
// Ported from QMapShack (src/qmapshack/map/CMapIMG.cpp: readSubfileBasics, loadSubDiv;
// src/qmapshack/map/garmin/CGarminPolygon.cpp: decode, decode2, bits_per_coord, CShiftReg;
// src/qmapshack/map/CMapIMG.h: tre_map_level_t, tre_subdiv_t, hdr_rgn_t),
// Copyright (C) 2008-2014 Oliver Eichler and contributors, GPL-3.0-or-later.
// Changes: rewritten in Swift without Qt. Labels and points are not decoded yet.

import BaseCampCore
import Foundation

/// A directory entry: where one part of a subfile is in the file.
typealias IMGPart = GarminIMG.Part

/// A map level of a subfile. Its subdivisions carry geometry at `bits` of coordinate resolution.
public struct GarminMapLevel: Equatable, Sendable {
    public let level: Int
    /// Larger numbers are finer detail.
    public let bits: Int
    /// An inherited level holds no geometry of its own; its cells only lead to the next finer level. Read from the
    /// top bit of the level byte, as QMapShack's `TRE_MAP_INHER`.
    public var inherited = false
}

/// One rectangular cell of a map level and the geometry records stored for it.
public struct GarminSubdivision: Equatable, Sendable {
    public let level: Int
    /// Area covered, in degrees.
    public let bounds: GeoBounds
    let shift: Int
    let rgnStart: Int
    let rgnEnd: Int
    let elements: UInt8
    let centerLongitude: Int
    let centerLatitude: Int
    /// Geometry in the RGN v2 sections, as ranges into the RGN part. Nil when absent.
    let polylines2: Range<Int>?
    let polygons2: Range<Int>?
}

/// A polyline or polygon from a map.
public struct GarminGeometry: Equatable, Sendable {
    public let isPolygon: Bool
    /// The Garmin feature type. Version 2 types are 0x10000 + (type << 8) + subtype.
    /// The TYP style that gives colours and widths is not ported yet.
    public let type: Int
    public let coordinates: [Coordinate]
}

// MARK: - Reading subdivisions and geometry

extension GarminIMG {
    /// The map levels of a subfile, from its TRE part.
    public func mapLevels(of subfile: String) throws -> [GarminMapLevel] {
        try levelRecords(of: subfile).map { GarminMapLevel(level: $0.level, bits: $0.bits, inherited: $0.inherited) }
    }

    /// Every subdivision of a subfile, in directory order.
    public func subdivisions(of subfile: String) throws -> [GarminSubdivision] {
        guard let tre = directory[subfile]?["TRE"], let rgn = directory[subfile]?["RGN"] else {
            throw GarminIMGError.malformedDirectory
        }
        let header = try readHeader(of: tre)
        let levels = try self.levelRecords(of: subfile)
        let rgnHeader = try reader.read(rgn.offset, min(0x61, Int(rgn.size)))
        let rgnBase = GarminIMG.field(rgnHeader, 0x15, 4)
        let rgnLength = GarminIMG.field(rgnHeader, 0x19, 4)
        let polygons2Base = GarminIMG.field(rgnHeader, 0x21, 4)
        let polygons2Length = GarminIMG.field(rgnHeader, 0x25, 4)
        let polylines2Base = GarminIMG.field(rgnHeader, 0x3D, 4)
        let polylines2Length = GarminIMG.field(rgnHeader, 0x41, 4)

        // The first subdivisions of each level but the last use 16-byte records (with a pointer to
        // the lower level); the last level uses 14-byte records.
        let levelOfIndex = levels.flatMap { record in Array(repeating: record, count: record.count) }
        let lastLevelCount = levels.last?.count ?? 0
        let longCount = levelOfIndex.count - lastLevelCount
        let needed = longCount * 16 + lastLevelCount * 14
        let table = try reader.read(tre.offset + UInt64(header.subdivisionOffset), header.subdivisionSize)
        guard table.count >= needed, levelOfIndex.count > 0 else {
            throw GarminIMGError.malformedDirectory
        }

        var records: [(level: Int, bits: Int, rgnOffset: Int, elements: UInt8, lng: Int, lat: Int, width: Int, height: Int)] = []
        var position = 0
        for (index, level) in levelOfIndex.enumerated() {
            let size = index < longCount ? 16 : 14
            records.append((
                level: level.level,
                bits: level.bits,
                rgnOffset: GarminIMG.field(table, position, 3),
                elements: table[position + 3],
                lng: GarminIMG.field(table, position + 4, 3),
                lat: GarminIMG.field(table, position + 7, 3),
                width: GarminIMG.field(table, position + 10, 2),
                height: GarminIMG.field(table, position + 12, 2)
            ))
            position += size
        }

        // RGN v2 ranges come from the TRE7 records, one per subdivision.
        var v2Records: [(polygons: Int, polylines: Int)] = []
        if header.length >= 0x9A, header.groupsSize > 0, header.groupsRecordSize >= 13 {
            let groups = try reader.read(tre.offset + UInt64(header.groupsOffset), header.groupsSize)
            let stride = header.groupsRecordSize
            for index in 0..<(groups.count / stride) {
                v2Records.append((
                    polygons: GarminIMG.field(groups, index * stride, 4),
                    polylines: GarminIMG.field(groups, index * stride + 4, 4)
                ))
            }
        }

        var result: [GarminSubdivision] = []
        for (index, record) in records.enumerated() {
            let shift = 24 - record.bits
            let rgnStart = rgnBase + record.rgnOffset
            let rgnEnd = index + 1 < records.count ? rgnBase + records[index + 1].rgnOffset : rgnBase + rgnLength
            let width = (record.width & 0x7FFF) << shift
            let height = record.height << shift
            let bounds = GeoBounds(
                north: GarminRGNDecoder.degrees(record.lat + height + 1),
                east: GarminRGNDecoder.degrees(record.lng + width + 1),
                south: GarminRGNDecoder.degrees(record.lat - height),
                west: GarminRGNDecoder.degrees(record.lng - width)
            )

            var polygons2: Range<Int>?
            var polylines2: Range<Int>?
            // Version 2 sections are used only when the RGN header declares them. Maps that declare zero length have
            // TRE7 offsets that point at other bytes, and QMapShack's decode2 rejects those too.
            if index < v2Records.count {
                if polygons2Length > 0 {
                    let start = v2Records[index].polygons + polygons2Base
                    let end = index + 1 < v2Records.count ? v2Records[index + 1].polygons + polygons2Base : polygons2Base + polygons2Length
                    polygons2 = start < end ? start..<end : nil
                }
                if polylines2Length > 0 {
                    let lineStart = v2Records[index].polylines + polylines2Base
                    let lineEnd = index + 1 < v2Records.count ? v2Records[index + 1].polylines + polylines2Base : polylines2Base + polylines2Length
                    polylines2 = lineStart < lineEnd ? lineStart..<lineEnd : nil
                }
            }

            result.append(GarminSubdivision(
                level: record.level,
                bounds: bounds,
                shift: shift,
                rgnStart: rgnStart,
                rgnEnd: rgnEnd,
                elements: record.elements,
                centerLongitude: record.lng,
                centerLatitude: record.lat,
                polylines2: polylines2,
                polygons2: polygons2
            ))
        }
        return result
    }

    /// The polylines and polygons stored for one subdivision.
    public func geometries(of subfile: String, in subdivision: GarminSubdivision) throws -> [GarminGeometry] {
        guard let rgn = directory[subfile]?["RGN"] else {
            throw GarminIMGError.malformedDirectory
        }
        var result: [GarminGeometry] = []

        // RGN v1: a small table of offsets at the start of the subdivision, then the objects.
        let elements = subdivision.elements
        let hasPoints = elements & 0x10 != 0
        let hasIndexedPoints = elements & 0x20 != 0
        let hasPolylines = elements & 0x40 != 0
        let hasPolygons = elements & 0x80 != 0
        if hasPolylines || hasPolygons {
            let objectCount = [hasPoints, hasIndexedPoints, hasPolylines, hasPolygons].filter { $0 }.count
            let block = try readRGN(rgn, from: subdivision.rgnStart, to: subdivision.rgnEnd)
            var cursor = subdivision.rgnStart
            let firstStart = (objectCount - 1) * 2 + subdivision.rgnStart
            var polylineStart = firstStart
            var polygonStart = firstStart
            // Indexed points, when they follow plain points, take a table entry that is not used here.
            if hasPoints && hasIndexedPoints {
                cursor += 2
            }
            if hasPolylines {
                if hasPoints || hasIndexedPoints {
                    polylineStart = block.u16(cursor) + subdivision.rgnStart
                    cursor += 2
                }
            }
            if hasPolygons {
                if hasPoints || hasIndexedPoints || hasPolylines {
                    polygonStart = block.u16(cursor) + subdivision.rgnStart
                    cursor += 2
                }
            }
            if hasPolylines {
                let end = hasPolygons ? polygonStart : subdivision.rgnEnd
                result += GarminRGNDecoder.decodeAll(
                    block, from: polylineStart, to: end, line: true,
                    shift: subdivision.shift, centerLongitude: subdivision.centerLongitude,
                    centerLatitude: subdivision.centerLatitude, version2: false
                )
            }
            if hasPolygons {
                result += GarminRGNDecoder.decodeAll(
                    block, from: polygonStart, to: subdivision.rgnEnd, line: false,
                    shift: subdivision.shift, centerLongitude: subdivision.centerLongitude,
                    centerLatitude: subdivision.centerLatitude, version2: false
                )
            }
        }

        // RGN v2: separate sections, addressed by the TRE7 records.
        if let range = subdivision.polygons2 {
            let block = try readRGN(rgn, from: range.lowerBound, to: range.upperBound)
            result += GarminRGNDecoder.decodeAll(
                block, from: range.lowerBound, to: range.upperBound, line: false,
                shift: subdivision.shift, centerLongitude: subdivision.centerLongitude,
                centerLatitude: subdivision.centerLatitude, version2: true
            )
        }
        if let range = subdivision.polylines2 {
            let block = try readRGN(rgn, from: range.lowerBound, to: range.upperBound)
            result += GarminRGNDecoder.decodeAll(
                block, from: range.lowerBound, to: range.upperBound, line: true,
                shift: subdivision.shift, centerLongitude: subdivision.centerLongitude,
                centerLatitude: subdivision.centerLatitude, version2: true
            )
        }
        return result
    }

    // MARK: Helpers

    fileprivate struct TREHeader {
        let length: Int
        let levelOffset: Int
        let levelSize: Int
        let subdivisionOffset: Int
        let subdivisionSize: Int
        let groupsOffset: Int
        let groupsSize: Int
        let groupsRecordSize: Int
    }

    fileprivate struct LevelRecord {
        let level: Int
        let bits: Int
        let count: Int
        var inherited = false
    }

    fileprivate func readHeader(of part: IMGPart) throws -> TREHeader {
        let bytes = try reader.read(part.offset, min(0xB7, Int(part.size)))
        return TREHeader(
            length: GarminIMG.field(bytes, 0, 2),
            levelOffset: GarminIMG.field(bytes, 0x21, 4),
            levelSize: GarminIMG.field(bytes, 0x25, 4),
            subdivisionOffset: GarminIMG.field(bytes, 0x29, 4),
            subdivisionSize: GarminIMG.field(bytes, 0x2D, 4),
            groupsOffset: GarminIMG.field(bytes, 0x7C, 4),
            groupsSize: GarminIMG.field(bytes, 0x80, 4),
            groupsRecordSize: GarminIMG.field(bytes, 0x84, 2)
        )
    }

    fileprivate func levelRecords(of subfile: String) throws -> [LevelRecord] {
        guard let tre = directory[subfile]?["TRE"], directory[subfile]?["RGN"] != nil else {
            throw GarminIMGError.malformedDirectory
        }
        let header = try readHeader(of: tre)
        let bytes = try reader.read(tre.offset + UInt64(header.levelOffset), header.levelSize)
        return stride(from: 0, to: bytes.count - 3, by: 4).map { index in
            LevelRecord(
                level: Int(bytes[index] & 0x0F),
                bits: Int(bytes[index + 1]),
                count: GarminIMG.field(bytes, index + 2, 2),
                inherited: bytes[index] & 0x80 != 0
            )
        }
    }

    fileprivate func readRGN(_ rgn: IMGPart, from start: Int, to end: Int) throws -> RGNBytes {
        let stop = min(end, Int(rgn.size))
        guard start >= 0, start < stop else {
            return RGNBytes(base: start, data: [])
        }
        return RGNBytes(base: start, data: try reader.read(rgn.offset + UInt64(start), stop - start))
    }

    /// A little-endian unsigned field, or zero when it lies outside the bytes.
    static func field(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> Int {
        (0..<count).reduce(0) { value, index in
            let position = offset + index
            let byte = position >= 0 && position < bytes.count ? Int(bytes[position]) : 0
            return value | byte << (8 * index)
        }
    }
}

// MARK: - Decoding geometry records

/// Bytes of an RGN section, addressed by their position in the RGN part.
struct RGNBytes {
    let base: Int
    let data: [UInt8]

    func byte(_ position: Int) -> Int {
        let index = position - base
        return index >= 0 && index < data.count ? Int(data[index]) : 0
    }

    func u16(_ position: Int) -> Int {
        byte(position) | byte(position + 1) << 8
    }

    func u24(_ position: Int) -> Int {
        byte(position) | byte(position + 1) << 8 | byte(position + 2) << 16
    }

    /// Interprets a 16-bit value as signed.
    static func signed16(_ value: Int) -> Int {
        value >= 0x8000 ? value - 0x10000 : value
    }
}

/// Sign conventions of one coordinate bitstream.
struct SignInfo {
    var xHasSign = true
    var yHasSign = true
    var negativeX = false
    var negativeY = false
    /// Bits at the start of the stream that hold the sign flags. QMapShack starts this count at 2.
    var signBits = 2
}

/// Reads packed coordinate deltas, least significant bit first. Port of QMapShack's CShiftReg.
struct CoordinateBits {
    private var register: UInt64 = 0
    private var bits = 0
    private var position: Int
    private var bytesLeft: Int
    private let source: RGNBytes
    private let bitsX: Int
    private let bitsY: Int
    private let bitsPerCoordinate: Int
    private let xMask: UInt64
    private let yMask: UInt64
    private let xSign: Int
    private let ySign: Int
    private let signs: SignInfo
    private let extraBit: Bool

    init(source: RGNBytes, start: Int, count: Int, bitsX: Int, bitsY: Int, extraBit: Bool, signs: SignInfo) {
        self.source = source
        self.position = start
        self.bytesLeft = max(0, count)
        self.bitsX = bitsX
        self.bitsY = bitsY
        self.bitsPerCoordinate = bitsX + bitsY + (extraBit ? 1 : 0)
        self.xMask = (UInt64(1) << UInt64(bitsX)) - 1
        self.yMask = (UInt64(1) << UInt64(bitsY)) - 1
        self.xSign = 1 << (bitsX - 1)
        self.ySign = 1 << (bitsY - 1)
        self.signs = signs
        self.extraBit = extraBit
        fill(bitsPerCoordinate + signs.signBits)
        register >>= UInt64(signs.signBits)
        bits -= signs.signBits
    }

    private mutating func fill(_ needed: Int) {
        while bits < needed && bytesLeft > 0 && bits >= 0 {
            register |= UInt64(source.byte(position)) << UInt64(bits)
            position += 1
            bytesLeft -= 1
            bits += 8
        }
    }

    /// Consumes `count` bits. Returns false when the stream is exhausted.
    private mutating func consume(_ count: Int) -> Bool {
        register >>= UInt64(count)
        bits -= count
        return bits >= 0
    }

    /// The next coordinate delta, or nil at the end of the stream.
    mutating func next() -> (x: Int, y: Int)? {
        guard bits >= bitsPerCoordinate else { return nil }
        if extraBit {
            guard consume(1) else { return nil }
        }

        var x = 0
        if signs.xHasSign {
            var tmp = 0
            while true {
                tmp = Int(register & xMask)
                if tmp != xSign { break }
                x += tmp - 1
                guard consume(bitsX) else { return nil }
                fill(bitsY + bitsX)
            }
            x = tmp < xSign ? x + tmp : tmp - (xSign << 1) - x
        } else {
            x = Int(register & xMask)
            if signs.negativeX { x = -x }
        }
        guard consume(bitsX) else { return nil }

        var y = 0
        if signs.yHasSign {
            var tmp = 0
            while true {
                tmp = Int(register & yMask)
                if tmp != ySign { break }
                y += tmp - 1
                guard consume(bitsY) else { return nil }
                fill(bitsY)
            }
            y = tmp < ySign ? y + tmp : tmp - (ySign << 1) - y
        } else {
            y = Int(register & yMask)
            if signs.negativeY { y = -y }
        }
        guard consume(bitsY) else { return nil }
        fill(bitsPerCoordinate)
        return (x, y)
    }
}

enum GarminRGNDecoder {
    /// Degrees for a 24-bit map coordinate. Values from 0x800000 up are negative.
    static func degrees(_ value: Int) -> Double {
        Double(value < 0x800000 ? value : value - 0x1000000) * 360 / 16_777_216
    }

    /// Decodes consecutive records between `start` and `end`.
    static func decodeAll(
        _ block: RGNBytes,
        from start: Int,
        to end: Int,
        line: Bool,
        shift: Int,
        centerLongitude: Int,
        centerLatitude: Int,
        version2: Bool
    ) -> [GarminGeometry] {
        var result: [GarminGeometry] = []
        var position = start
        while position < end {
            let decoded = version2
                ? decodeVersion2(block, at: position, end: end, line: line, shift: shift,
                                 centerLongitude: centerLongitude, centerLatitude: centerLatitude)
                : decodeVersion1(block, at: position, end: end, line: line, shift: shift,
                                 centerLongitude: centerLongitude, centerLatitude: centerLatitude)
            guard let geometry = decoded.geometry, decoded.next > position else { break }
            result.append(geometry)
            position = decoded.next
        }
        return result
    }

    /// RGN v1 record: a type byte, label info, first point deltas, then the packed coordinates.
    static func decodeVersion1(
        _ bytes: RGNBytes,
        at start: Int,
        end: Int,
        line: Bool,
        shift: Int,
        centerLongitude: Int,
        centerLatitude: Int
    ) -> (geometry: GarminGeometry?, next: Int) {
        var position = start
        var type = bytes.byte(position)
        position += 1
        let twoByteLength = type & 0x80 != 0
        type = line ? type & 0x3F : type & 0x7F

        let labelInfo = bytes.u24(position)
        position += 3
        let extraBit = labelInfo & 0x400000 != 0

        // The first point's deltas are signed 16-bit values in QMapShack (qint16).
        let firstLongitude = RGNBytes.signed16(bytes.u16(position))
        position += 2
        let firstLatitude = RGNBytes.signed16(bytes.u16(position))
        position += 2

        let length: Int
        var total = 10
        if twoByteLength {
            length = bytes.u16(position)
            position += 2
            total += length + 1
        } else {
            length = bytes.byte(position)
            position += 1
            total += length
        }
        let next = start + total
        guard next <= end, length >= 0 else { return (nil, end) }

        let baseInfo = bytes.byte(position)
        position += 1
        guard let fields = bitFields(base: baseInfo, first: bytes.byte(position), version2: false) else {
            return (nil, next)
        }
        var stream = CoordinateBits(
            source: bytes, start: position, count: length,
            bitsX: fields.bitsX, bitsY: fields.bitsY, extraBit: extraBit, signs: fields.signs
        )
        let coordinates = coordinateList(
            firstLongitude: firstLongitude, firstLatitude: firstLatitude, stream: &stream,
            shift: shift, centerLongitude: centerLongitude, centerLatitude: centerLatitude
        )
        return (GarminGeometry(isPolygon: !line, type: type, coordinates: coordinates), next)
    }

    /// RGN v2 record: a two-byte type, first point deltas, then the packed coordinates.
    static func decodeVersion2(
        _ bytes: RGNBytes,
        at start: Int,
        end: Int,
        line: Bool,
        shift: Int,
        centerLongitude: Int,
        centerLatitude: Int
    ) -> (geometry: GarminGeometry?, next: Int) {
        var position = start
        let mainType = bytes.byte(position)
        let subtype = bytes.byte(position + 1)
        position += 2
        let type = 0x10000 + (mainType << 8) + (subtype & 0x1F)
        let hasLabel = subtype & 0x20 != 0

        // The first point's deltas are signed 16-bit values in QMapShack (qint16).
        let firstLongitude = RGNBytes.signed16(bytes.u16(position))
        position += 2
        let firstLatitude = RGNBytes.signed16(bytes.u16(position))
        position += 2

        let length: Int
        var total = 6
        if bytes.byte(position) & 1 == 0 {
            length = (bytes.u16(position) >> 2) - 1
            position += 2
            total += 2
        } else {
            length = (bytes.byte(position) >> 1) - 1
            position += 1
            total += 1
        }
        let baseInfo = bytes.byte(position)
        position += 1
        total += length + 1
        if hasLabel {
            total += 3
        }
        let next = start + total
        guard next <= end, length >= 0 else { return (nil, end) }

        guard let fields = bitFields(base: baseInfo, first: bytes.byte(position), version2: true) else {
            return (nil, next)
        }
        var stream = CoordinateBits(
            source: bytes, start: position, count: length,
            bitsX: fields.bitsX, bitsY: fields.bitsY, extraBit: false, signs: fields.signs
        )
        let coordinates = coordinateList(
            firstLongitude: firstLongitude, firstLatitude: firstLatitude, stream: &stream,
            shift: shift, centerLongitude: centerLongitude, centerLatitude: centerLatitude
        )
        return (GarminGeometry(isPolygon: !line, type: type, coordinates: coordinates), next)
    }

    /// Bit widths and sign conventions from the base byte and the first bitstream byte.
    static func bitFields(base: Int, first: Int, version2: Bool) -> (bitsX: Int, bitsY: Int, signs: SignInfo)? {
        var signs = SignInfo()
        // Each "same sign" flag takes a bit, followed by the sign itself when it is set (QMapShack's bits_per_coord).
        var mask = 1
        let xSameSign = first & mask != 0
        mask <<= 1
        if xSameSign {
            signs.xHasSign = false
            signs.negativeX = first & mask != 0
            mask <<= 1
            signs.signBits += 1
        } else {
            signs.xHasSign = true
        }
        var bitsX = bitsPerCoordinate(base & 0x0F, signed: signs.xHasSign)

        let ySameSign = first & mask != 0
        mask <<= 1
        if ySameSign {
            signs.yHasSign = false
            signs.negativeY = first & mask != 0
            mask <<= 1
            signs.signBits += 1
        } else {
            signs.yHasSign = true
        }
        var bitsY = bitsPerCoordinate((base >> 4) & 0x0F, signed: signs.yHasSign)

        if version2 {
            signs.signBits += 1
            if first & mask != 0 {
                bitsX += 1
                bitsY += 1
            }
        }
        guard bitsX >= 1, bitsY >= 1, bitsX <= 32, bitsY <= 32 else { return nil }
        return (bitsX, bitsY, signs)
    }

    static func bitsPerCoordinate(_ base: Int, signed: Bool) -> Int {
        var count = 2
        count += base <= 9 ? base : 2 * base - 9
        if signed {
            count += 1
        }
        return count
    }

    private static func coordinateList(
        firstLongitude: Int,
        firstLatitude: Int,
        stream: inout CoordinateBits,
        shift: Int,
        centerLongitude: Int,
        centerLatitude: Int
    ) -> [Coordinate] {
        let negativeCenter = centerLongitude >= 0x800000
        var longitude = (firstLongitude << shift) + centerLongitude
        var latitude = (firstLatitude << shift) + centerLatitude
        if longitude >= 0x800000 && !negativeCenter {
            longitude = 0x7FFFFF
        }
        var result = [Coordinate(latitude: degrees(latitude), longitude: degrees(longitude))]
        while let delta = stream.next() {
            longitude += delta.x << shift
            latitude += delta.y << shift
            if longitude >= 0x800000 && !negativeCenter {
                longitude = 0x7FFFFF
            }
            result.append(Coordinate(latitude: degrees(latitude), longitude: degrees(longitude)))
        }
        return result
    }
}
