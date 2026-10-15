// Copyright (C) 2026 the HighCamp contributors
//
// This file is part of HighCamp, free software under the GNU General Public License
// version 3 or later. See LICENSE.
//
// Ported from QMapShack (src/qmapshack/map/garmin/IGarminStrTbl.cpp, CGarminStrTbl6.cpp, CGarminStrTbl8.cpp,
// CGarminStrTblUtf8.cpp; the LBL header from src/qmapshack/map/CMapIMG.h and CMapIMG.cpp, readSubfileBasics),
// Copyright (C) 2008-2014 Oliver Eichler and contributors, GPL-3.0-or-later. Changes: rewritten in Swift without
// Qt; the LBL and NET parts are read whole.

import Foundation

/// The names a map subfile gives its points, lines and areas: its LBL part's string table.
public struct GarminLabels: Sendable {
    private let bytes: [UInt8]
    private let stringsStart: Int
    private let stringsLength: Int
    private let shift: Int
    private let coding: Int
    private let poiStart: Int
    private let poiLength: Int
    private let encoding: String.Encoding
    /// The NET part, whose first table gives each road's name: its bytes, the table's start and length, and shift.
    private var net: (bytes: [UInt8], start: Int, length: Int, shift: Int)?

    /// Reads an LBL part, and the NET part for road names when the subfile has one. Nil when the coding is not one
    /// QMapShack knows (6-bit, 8-bit or UTF-8).
    public init?(bytes: [UInt8], net: [UInt8]? = nil) {
        if let net, net.count >= 0x1E {
            self.net = (net, GarminIMG.field(net, 0x15, 4), GarminIMG.field(net, 0x19, 4), Int(net[0x1D]))
        }
        guard bytes.count >= 0x60 else { return nil }
        func field(_ offset: Int, _ count: Int) -> Int { GarminIMG.field(bytes, offset, count) }
        coding = Int(bytes[0x1E])
        guard [0x06, 0x09, 0x0A].contains(coding) else { return nil }
        self.bytes = bytes
        stringsStart = field(0x15, 4)
        stringsLength = field(0x19, 4)
        shift = Int(bytes[0x1D])
        poiStart = field(0x57, 4)
        poiLength = field(0x5B, 4)
        let codepage = field(0, 2) > 0xAA ? field(0xAA, 2) : 0
        encoding = Self.encoding(codepage: codepage, coding: coding)
    }

    private static func encoding(codepage: Int, coding: Int) -> String.Encoding {
        if coding == 0x0A || codepage == 65001 {
            return .utf8
        }
        switch codepage {
        case 1250: return .windowsCP1250
        case 1251: return .windowsCP1251
        case 1252: return .windowsCP1252
        case 1253: return .windowsCP1253
        case 1254: return .windowsCP1254
        default: return .isoLatin1
        }
    }

    /// The name at `offset`, as a point or line record gives it. `poi` offsets go through the LBL6 table first, as
    /// for points whose record has the 0x400000 flag. The parts of a multi-part name are joined with spaces. Nil
    /// for no name.
    public func name(at offset: Int, poi: Bool = false, inNET: Bool = false) -> String? {
        var position = offset
        if inNET {
            // A road's record in NET1 starts with the offset of its first name.
            guard let net else { return nil }
            let record = net.start + (offset << net.shift)
            guard (offset << net.shift) + 4 <= net.length else { return nil }
            let value = GarminIMG.field(net.bytes, record, 4)
            guard value & 0x40_0000 == 0 else { return nil }
            position = value & 0x3F_FFFF
        } else if poi {
            guard offset + 4 <= poiLength else { return nil }
            position = GarminIMG.field(bytes, poiStart + offset, 4) & 0x3F_FFFF
        }
        position <<= shift
        guard position < stringsLength else { return nil }
        let start = stringsStart + position
        let end = min(stringsStart + stringsLength, start + 200, bytes.count)
        guard start < end else { return nil }
        let parts = coding == 0x06 ? sixBit(start, end) : eightBit(start, end)
        let name = parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// 8-bit or UTF-8 text up to a zero byte. Bytes 0x1B to 0x1F separate parts; bytes below 0x07 are codes for
    /// shields and are left out.
    private func eightBit(_ start: Int, _ end: Int) -> [String] {
        var parts: [String] = []
        var buffer: [UInt8] = []
        func flush() {
            if !buffer.isEmpty, let text = String(bytes: buffer, encoding: encoding) {
                parts.append(text)
            }
            buffer.removeAll()
        }
        for position in start..<end {
            let byte = bytes[position]
            if byte == 0 {
                break
            } else if (0x1B...0x1F).contains(byte) {
                flush()
            } else if byte >= 0x07 {
                buffer.append(byte)
            }
        }
        flush()
        return parts
    }

    private static let sixBitLetters: [Character?] = Array(" ABCDEFGHIJKLMNOPQRSTUVWXYZ").map { $0 }
        + [nil, nil, nil, nil, nil] + Array("0123456789").map { $0 } + [nil, nil, nil, nil, nil, nil]
    private static let sixBitSymbols: [Character?] = Array("@!\"#$%&'()*+,-./").map { $0 }
        + Array(repeating: nil, count: 10) + Array(":;<=>?").map { $0 } + Array(repeating: nil, count: 11)
        + Array("[\\]^_").map { $0 }
    private static let sixBitLower: [Character?] = Array("`abcdefghijklmnopqrstuvwxyz").map { $0 }

    /// Garmin's 6-bit packed capitals, with escapes for symbols (0x1C) and small letters (0x1B).
    private func sixBit(_ start: Int, _ end: Int) -> [String] {
        var position = start
        var register: UInt32 = 0
        var bits = 0
        func fill() {
            if bits < 6 {
                let byte = position < end ? UInt32(bytes[position]) : 0
                position += 1
                register |= byte << UInt32(24 - bits)
                bits += 8
            }
        }
        func next() -> Int {
            let value = Int(register >> 26)
            register <<= 6
            bits -= 6
            fill()
            return value
        }
        fill()
        var parts: [String] = []
        var buffer = ""
        for _ in 0..<199 {
            let code = next()
            if code > 0x2F {
                break
            }
            if let letter = Self.sixBitLetters[code] {
                buffer.append(letter)
            } else if code == 0x1C {
                let symbol = next()
                if symbol < Self.sixBitSymbols.count, let character = Self.sixBitSymbols[symbol] {
                    buffer.append(character)
                }
            } else if code == 0x1B {
                let lower = next()
                if lower < Self.sixBitLower.count, let character = Self.sixBitLower[lower] {
                    buffer.append(character)
                }
            } else if code > 0x1C && code < 0x20 {
                if !buffer.isEmpty {
                    parts.append(buffer)
                }
                buffer = ""
            }
        }
        if !buffer.isEmpty {
            parts.append(buffer)
        }
        return parts
    }
}

public extension GarminIMG {
    /// The string table of a subfile, or nil when it has no LBL part or an unknown coding.
    func labels(of subfile: String) throws -> GarminLabels? {
        guard let bytes = try partBytes(subfile, part: "LBL") else { return nil }
        return GarminLabels(bytes: bytes, net: try partBytes(subfile, part: "NET"))
    }
}
