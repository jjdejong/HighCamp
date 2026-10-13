// Copyright (C) 2026 the BaseCamp Clone contributors
//
// This file is part of BaseCamp Clone, free software under the GNU General Public License
// version 3 or later. See LICENSE.
//
// Ported from QMapShack (src/qmapshack/map/CMapIMG.cpp, src/qmapshack/map/CMapIMG.h and
// src/qmapshack/helpers/Platform.h), Copyright (C) 2008-2014 Oliver Eichler and contributors,
// GPL-3.0-or-later. Changes: rewritten in Swift without Qt; the file is read in place rather
// than loaded whole; only the container directory and the TRE header bounds are ported so far.

import Foundation

/// Errors reading a Garmin IMG file.
public enum GarminIMGError: Error, Equatable {
    /// The file does not start with the Garmin IMG header.
    case notGarminIMG
    /// The file ends before a structure that should be there.
    case truncated
    /// The block directory does not describe any subfile.
    case malformedDirectory
    /// A TRE header is flagged as locked. QMapShack refuses these too.
    case locked
    /// The file uses the NT layout (a GMP part). Not supported, as in QMapShack.
    case ntFormat
}

/// A rectangle on the globe, in degrees. North and east are positive.
public struct GeoBounds: Equatable, Sendable {
    public var north: Double
    public var east: Double
    public var south: Double
    public var west: Double

    public init(north: Double, east: Double, south: Double, west: Double) {
        self.north = north
        self.east = east
        self.south = south
        self.west = west
    }

    /// The smallest bounds containing both.
    public func union(_ other: GeoBounds) -> GeoBounds {
        GeoBounds(
            north: max(north, other.north),
            east: max(east, other.east),
            south: min(south, other.south),
            west: min(west, other.west)
        )
    }
}

/// One named subfile of a map: its parts (TRE, RGN, LBL, ...) and the area it covers.
public struct IMGSubfile: Equatable, Sendable {
    public let name: String
    /// Part types present, sorted, for example ["LBL", "RGN", "TRE"].
    public let parts: [String]
    /// From the TRE header. Nil when the subfile has no TRE part or the header is empty.
    public let bounds: GeoBounds?
    /// An overlay, such as a contour map, meant to be drawn over another map without a background. From bit 1 of
    /// the TRE header's POI flags (byte 0x3F), as QMapShack's `isTransparent`.
    public var isTransparent = false
}

/// A Garmin IMG map, read as a directory of subfiles. The file is read in place, not loaded whole.
public final class GarminIMG {
    public let url: URL
    /// The map description from the header.
    public let description: String
    public let blockSize: Int
    public let subfiles: [IMGSubfile]
    /// The file reader and the directory, kept for reading subfile data on demand.
    let reader: IMGReader
    let directory: [String: [String: Part]]

    /// True when any subfile is an overlay (see `IMGSubfile.isTransparent`). QMapShack treats such a map as transparent.
    public var isTransparent: Bool {
        subfiles.contains(where: \.isTransparent)
    }

    /// The map area: the union of every subfile's bounds, or nil when there are none.
    public var coverage: GeoBounds? {
        subfiles.compactMap(\.bounds).reduce(nil) { total, bounds in
            total.map { $0.union(bounds) } ?? bounds
        }
    }

    public init(url: URL) throws {
        self.url = url
        let reader = try IMGReader(url: url)

        let header = try reader.read(0, GarminIMG.headerSize)
        guard GarminIMG.ascii(header[0x10..<0x16]) == "DSKIMG",
              GarminIMG.ascii(header[0x41..<0x47]) == "GARMIN" else {
            throw GarminIMGError.notGarminIMG
        }
        let shift = Int(header[0x61]) + Int(header[0x62])
        guard shift < 30 else {
            throw GarminIMGError.notGarminIMG
        }
        blockSize = 1 << shift
        description = GarminIMG.ascii(header[0x49..<0x5D]) + GarminIMG.ascii(header[0x65..<0x84])

        let directory = try GarminIMG.readDirectory(reader, blockSize: blockSize)
        if directory.parts.values.contains(where: { $0["GMP"] != nil }) {
            throw GarminIMGError.ntFormat
        }

        var subfiles: [IMGSubfile] = []
        for name in directory.names {
            let parts = directory.parts[name] ?? [:]
            var bounds: GeoBounds?
            var transparent = false
            if let tre = parts["TRE"], parts["RGN"] != nil {
                bounds = try GarminIMG.treBounds(reader, part: tre)
                if tre.size > 0x3F {
                    transparent = try reader.read(tre.offset + 0x3F, 1)[0] & 0x02 != 0
                }
            }
            subfiles.append(IMGSubfile(name: name, parts: parts.keys.sorted(), bounds: bounds, isTransparent: transparent))
        }
        self.subfiles = subfiles
        self.reader = reader
        self.directory = directory.parts
    }

    /// Size of the IMG header, which the block directory follows.
    static let headerSize = 0x600
    /// Every directory entry is one 512-byte block.
    static let directoryEntrySize = 512

    struct Part {
        let offset: UInt64
        let size: UInt32
    }

    /// Subfile names in directory order, and each subfile's parts by type.
    private static func readDirectory(
        _ reader: IMGReader,
        blockSize: Int
    ) throws -> (names: [String], parts: [String: [String: Part]]) {
        var offset = UInt64(headerSize)

        func entry(at position: UInt64) throws -> [UInt8]? {
            guard position + UInt64(directoryEntrySize) <= reader.fileSize else { return nil }
            return try reader.read(position, directoryEntrySize)
        }

        // Dummy blocks before the first entry are skipped.
        var current = try entry(at: offset)
        while let block = current, block[0] == 0x00 {
            offset += UInt64(directoryEntrySize)
            current = try entry(at: offset)
        }

        var names: [String] = []
        var parts: [String: [String: Part]] = [:]
        // A subfile can be split over several entries. Only the first entry with a size is used.
        var seen = Set<[UInt8]>()
        while let block = current, block[0] == 0x01 {
            let key = Array(block[1..<12])
            let size = UInt32(littleEndian(block, at: 12, count: 4))
            let firstBlock = littleEndian(block, at: 0x20, count: 2)
            if size != 0, !seen.contains(key), block[1] != 0x20 {
                seen.insert(key)
                let name = ascii(block[1..<9])
                // The MAPSOURC and SENDMAP2 entries are not map data, as in QMapShack.
                if name != "MAPSOURC" && name != "SENDMAP2" {
                    let type = ascii(block[9..<12])
                    if parts[name] == nil {
                        parts[name] = [:]
                        names.append(name)
                    }
                    parts[name]?[type] = Part(offset: firstBlock * UInt64(blockSize), size: size)
                }
            }
            offset += UInt64(directoryEntrySize)
            current = try entry(at: offset)
        }

        if offset == UInt64(headerSize) || offset >= reader.fileSize {
            throw GarminIMGError.malformedDirectory
        }
        return (names, parts)
    }

    /// Map bounds from the TRE header. Coordinates are 24-bit values in units of 360 / 2^24 degrees.
    private static func treBounds(_ reader: IMGReader, part: Part) throws -> GeoBounds? {
        guard part.size >= 0x21 else {
            throw GarminIMGError.malformedDirectory
        }
        let header = try reader.read(part.offset, 0x21)
        if header[0x0D] & 0x80 != 0 {
            throw GarminIMGError.locked
        }

        let north = degrees(header, at: 0x15)
        var east = degrees(header, at: 0x18)
        let south = degrees(header, at: 0x1B)
        let west = degrees(header, at: 0x1E)
        // Empty header: all four bounds zero. Such a subfile covers no area.
        if north == 0 && east == 0 && south == 0 && west == 0 {
            return nil
        }
        // The same sign corrections QMapShack applies to degenerate and wrapped boundaries.
        if east == west {
            east = -east
        }
        if west > 0 && east < 0 {
            east = -east
        }
        return GeoBounds(north: north, east: east, south: south, west: west)
    }

    private static func degrees(_ bytes: [UInt8], at offset: Int) -> Double {
        var value = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16
        if value >= 0x800000 {
            value -= 0x1000000
        }
        return Double(value) * 360 / 16_777_216
    }

    private static func littleEndian(_ bytes: [UInt8], at offset: Int, count: Int) -> UInt64 {
        (0..<count).reduce(UInt64(0)) { $0 | UInt64(bytes[offset + $1]) << (8 * UInt64($1)) }
    }

    /// Text from a fixed-width field, without padding.
    static func ascii<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
    }
}

/// Reads a file's bytes, applying the IMG XOR key. Garmin IMG files may store every byte XORed with
/// the first byte of the file; a zero first byte means no XOR.
final class IMGReader {
    let fileSize: UInt64
    private let handle: FileHandle
    private let mask: UInt8

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        fileSize = try handle.seekToEnd()
        guard fileSize >= UInt64(GarminIMG.headerSize) else {
            throw GarminIMGError.notGarminIMG
        }
        try handle.seek(toOffset: 0)
        mask = try handle.read(upToCount: 1)?.first ?? 0
    }

    deinit {
        try? handle.close()
    }

    func read(_ offset: UInt64, _ count: Int) throws -> [UInt8] {
        guard offset + UInt64(count) <= fileSize else {
            throw GarminIMGError.truncated
        }
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw GarminIMGError.truncated
        }
        var bytes = [UInt8](data)
        if mask != 0 {
            for index in bytes.indices {
                bytes[index] ^= mask
            }
        }
        return bytes
    }
}
