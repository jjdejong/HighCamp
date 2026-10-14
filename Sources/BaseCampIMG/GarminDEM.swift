// Copyright (C) 2026 the BaseCamp Clone contributors
//
// This file is part of BaseCamp Clone, free software under the GNU General Public License version 3.
// See LICENSE.
//
// Ported from GPXSee (src/map/IMG/demfile.cpp, demfile.h, demtile.h, demtree.cpp, jls.cpp, jls.h),
// Copyright (C) Martin Tůma, GPL-3.0 (only). Changes: rewritten in Swift without Qt; the DEM part is read
// whole into memory; heights are looked up on the level's whole pixel grid rather than tile by tile.

import Foundation

/// The heights a Garmin IMG map carries in its DEM part: a grid per level, cut into tiles, each tile coded
/// with a variant of JPEG-LS. Heights are in metres.
public final class GarminDEM: @unchecked Sendable {
    /// One level of the grid, from finest to coarsest as the map lists them.
    public struct Level: Sendable {
        /// The map level this grid goes with.
        public let level: Int
        /// The north-west corner of the grid, and the size of one pixel, in degrees.
        public let north: Double
        public let west: Double
        public let pixelWidth: Double
        public let pixelHeight: Double
        /// Tiles across and down, and the size in pixels of every tile but the last in each direction.
        let columns: Int
        let rows: Int
        let tileWidth: Int
        let tileHeight: Int
        /// Pixels across and down the whole grid.
        public let width: Int
        public let height: Int
        let dataOffset: Int
        let factor: Int
        let minimumHeight: Int
        let maximumHeight: Int
        let tiles: [Tile]

        /// The grid's south-east corner.
        public var south: Double { north - Double(height - 1) * pixelHeight }
        public var east: Double { west + Double(width - 1) * pixelWidth }
    }

    struct Tile: Sendable {
        let width: Int
        let height: Int
        let offset: Int
        let base: Int
        let difference: Int
        let flags: Int
    }

    public let levels: [Level]
    /// Heights stored in feet, converted on reading.
    let inFeet: Bool
    private let bytes: [UInt8]
    private let lock = NSLock()
    private var decoded: [TileKey: [Int16]] = [:]
    private var decodedOrder: [TileKey] = []
    /// Decoded tiles kept, per DEM part. A tile is a few thousand heights.
    static let maximumDecodedTiles = 256

    private struct TileKey: Hashable {
        let level: Int
        let index: Int
    }

    /// Reads the DEM part of a map subfile. Throws when the part is malformed; a part without levels gives no levels.
    public init(bytes: [UInt8]) throws {
        self.bytes = bytes
        var reader = ByteReader(bytes: bytes, position: 0x15)
        let flags = try reader.u32()
        inFeet = flags & 1 != 0
        let zooms = try reader.u16()
        _ = try reader.u32()
        let recordSize = try reader.u16()
        let records = Int(try reader.u32())

        var levels: [Level] = []
        for zoom in 0..<zooms {
            reader.position = records + zoom * recordSize
            let layer = try reader.u8()
            let level = try reader.u8()
            let tileHeight = try reader.u32()
            let tileWidth = try reader.u32()
            let lastHeight = try reader.u32()
            let lastWidth = try reader.u32()
            let factor = try reader.u16()
            let columns = try reader.u32()
            let rows = try reader.u32()
            let encoding = try reader.u16()
            _ = try reader.u16()
            let table = try reader.u32()
            let data = try reader.u32()
            let longitude = try reader.i32()
            let latitude = try reader.i32()
            let yr = try reader.u32()
            let xr = try reader.u32()
            let minimumHeight = try reader.i16()
            let maximumHeight = try reader.i16()
            guard layer == 0 else { continue }

            var tiles: [Tile] = []
            tiles.reserveCapacity((rows + 1) * (columns + 1))
            reader.position = table
            for row in 0...rows {
                for column in 0...columns {
                    let offset = try reader.unsigned((encoding & 0x3) + 1)
                    let base = try encoding & 0x4 != 0 ? reader.i16() : reader.i8()
                    let difference = try encoding & 0x8 != 0 ? reader.u16() : reader.u8()
                    let tileFlags = try encoding & 0x10 != 0 ? reader.u8() : 0
                    tiles.append(Tile(
                        width: column == columns ? lastWidth + 1 : tileWidth,
                        height: row == rows ? lastHeight + 1 : tileHeight,
                        offset: offset, base: base, difference: difference, flags: tileFlags
                    ))
                }
            }
            levels.append(Level(
                level: level,
                north: Self.degrees(latitude), west: Self.degrees(longitude),
                pixelWidth: Self.degrees(xr), pixelHeight: Self.degrees(yr),
                columns: columns + 1, rows: rows + 1, tileWidth: tileWidth, tileHeight: tileHeight,
                width: columns * tileWidth + lastWidth + 1, height: rows * tileHeight + lastHeight + 1,
                dataOffset: data, factor: factor, minimumHeight: minimumHeight, maximumHeight: maximumHeight,
                tiles: tiles
            ))
        }
        self.levels = levels
    }

    /// 32-bit map units to degrees.
    static func degrees<T: BinaryInteger>(_ value: T) -> Double {
        Double(value) / Double(1 << 31) * 180
    }

    /// The level to use for pixels of `degreesPerPixel`: the coarsest that is at least as fine, or the finest.
    public func level(forDegreesPerPixel degreesPerPixel: Double) -> Int? {
        guard !levels.isEmpty else { return nil }
        let fineEnough = levels.indices.filter { levels[$0].pixelWidth <= degreesPerPixel * 1.01 }
        if let coarsest = fineEnough.max(by: { levels[$0].pixelWidth < levels[$1].pixelWidth }) {
            return coarsest
        }
        return levels.indices.min { levels[$0].pixelWidth < levels[$1].pixelWidth }
    }

    /// The height at a place, between the four grid pixels around it, on level `level`. Nil outside the grid or
    /// where the map has no height (sea, say).
    public func elevation(latitude: Double, longitude: Double, level index: Int) -> Double? {
        let level = levels[index]
        let x = (longitude - level.west) / level.pixelWidth
        let y = (level.north - latitude) / level.pixelHeight
        guard x >= 0, y >= 0, x <= Double(level.width - 1), y <= Double(level.height - 1) else { return nil }
        let column = min(Int(x), level.width - 2 < 0 ? 0 : level.width - 2)
        let row = min(Int(y), level.height - 2 < 0 ? 0 : level.height - 2)
        let dx = x - Double(column), dy = y - Double(row)
        guard let p0 = pixel(column, row, level: index) else { return nil }
        let p1 = pixel(column + 1, row, level: index) ?? p0
        let p2 = pixel(column, row + 1, level: index) ?? p0
        let p3 = pixel(column + 1, row + 1, level: index) ?? p0
        return p0 * (1 - dx) * (1 - dy) + p1 * dx * (1 - dy) + p2 * (1 - dx) * dy + p3 * dx * dy
    }

    /// The height of one grid pixel of level `level`, or nil where there is none.
    func pixel(_ x: Int, _ y: Int, level index: Int) -> Double? {
        let level = levels[index]
        guard x >= 0, y >= 0, x < level.width, y < level.height else { return nil }
        let column = min(x / max(level.tileWidth, 1), level.columns - 1)
        let row = min(y / max(level.tileHeight, 1), level.rows - 1)
        let tileIndex = row * level.columns + column
        let tile = level.tiles[tileIndex]
        let localX = x - column * level.tileWidth
        let localY = y - row * level.tileHeight
        guard localX < tile.width, localY < tile.height,
              let heights = heights(level: index, tile: tileIndex) else { return nil }
        let value = heights[localY * tile.width + localX]
        return value == Self.noHeight ? nil : Double(value)
    }

    static let noHeight = Int16.min

    /// The decoded heights of one tile, row by row, kept for the next lookups.
    func heights(level index: Int, tile tileIndex: Int) -> [Int16]? {
        let key = TileKey(level: index, index: tileIndex)
        lock.lock()
        if let cached = decoded[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        guard let heights = decode(level: levels[index], tile: levels[index].tiles[tileIndex]) else { return nil }
        lock.lock()
        if decoded[key] == nil {
            decoded[key] = heights
            decodedOrder.append(key)
            if decodedOrder.count > Self.maximumDecodedTiles {
                decoded[decodedOrder.removeFirst()] = nil
            }
        }
        lock.unlock()
        return heights
    }

    private func decode(level: Level, tile: Tile) -> [Int16]? {
        let count = tile.width * tile.height
        if tile.difference == 0 {
            let value = tile.flags != 0 ? Self.noHeight : Int16(clamping: inFeet ? Self.metres(feet: tile.base) : tile.base)
            return [Int16](repeating: value, count: count)
        }
        let start = level.dataOffset + tile.offset
        guard start < bytes.count else { return nil }
        var grid = [Int](repeating: 0, count: count)
        let decoder = JLSDecoder(maximum: tile.difference, near: level.factor)
        var bits = BitReader(bytes: bytes, position: start)
        guard decoder.decode(&bits, width: tile.width, height: tile.height, into: &grid) else { return nil }

        let limit = Self.limit(tile, factor: level.factor)
        return grid.map { raw in
            guard raw < limit else { return Self.noHeight }
            var value = raw + tile.base
            value = min(max(value, level.minimumHeight), level.maximumHeight)
            if inFeet {
                value = Self.metres(feet: value)
            }
            return Int16(clamping: value)
        }
    }

    /// Coded values at or above this mark pixels without a height.
    static func limit(_ tile: Tile, factor: Int) -> Int {
        let odd = tile.flags & 1 != 0 ? 1 : 0
        var limit = odd == 1 ? tile.difference - factor : tile.difference + 1
        if tile.flags > 1 {
            for bit in 1..<8 where (tile.flags >> bit) & 1 != 0 {
                limit = (limit - 1) - (factor << odd)
            }
        }
        // The original compares against the limit as an unsigned 16-bit value.
        return limit < 0 ? limit + 65536 : limit
    }

    static func metres(feet: Int) -> Int {
        feet * 381 / 1250
    }
}

public extension GarminIMG {
    /// The heights in a subfile's DEM part, or nil when it has none.
    func dem(of subfile: String) throws -> GarminDEM? {
        guard let bytes = try partBytes(subfile, part: "DEM") else { return nil }
        return try GarminDEM(bytes: bytes)
    }
}

/// Little-endian reads from a byte array.
struct ByteReader {
    let bytes: [UInt8]
    var position: Int

    mutating func u8() throws -> Int {
        guard position < bytes.count else { throw GarminIMGError.truncated }
        defer { position += 1 }
        return Int(bytes[position])
    }

    mutating func i8() throws -> Int {
        Int(Int8(bitPattern: UInt8(try u8())))
    }

    mutating func u16() throws -> Int {
        let low = try u8()
        let high = try u8()
        return low | high << 8
    }

    mutating func i16() throws -> Int {
        Int(Int16(bitPattern: UInt16(try u16())))
    }

    mutating func u32() throws -> Int {
        let low = try u16()
        let high = try u16()
        return low | high << 16
    }

    mutating func i32() throws -> Int {
        Int(Int32(bitPattern: UInt32(try u32())))
    }

    mutating func unsigned(_ count: Int) throws -> Int {
        var value = 0
        for index in 0..<count {
            value |= try u8() << (8 * index)
        }
        return value
    }
}

/// The bit stream of a coded tile: a 32-bit window, most significant bit first. Past the end of the data it reads
/// zeros.
struct BitReader {
    let bytes: [UInt8]
    var position: Int
    private(set) var value: UInt32 = 0
    private var shift = -8

    init(bytes: [UInt8], position: Int) {
        self.bytes = bytes
        self.position = position
        for _ in 0..<4 {
            value = value << 8 | UInt32(nextByte())
        }
    }

    private mutating func nextByte() -> UInt8 {
        defer { position += 1 }
        return position < bytes.count ? bytes[position] : 0
    }

    mutating func consume(_ count: Int) {
        value = count >= 32 ? 0 : value << UInt32(count)
        shift += count
        while shift >= 0 {
            value |= UInt32(nextByte()) << UInt32(shift)
            shift -= 8
        }
    }

    var top: UInt32 { value >> 24 }
    var isNegative: Bool { value & 0x8000_0000 != 0 }
}

/// Garmin's variant of the JPEG-LS decoder (ITU T.87), as GPXSee reads it: one context for the regular mode and
/// two for run interruptions.
struct JLSDecoder {
    let maximum: Int
    let near: Int
    let range: Int
    let qbpp: Int
    let limit: Int

    init(maximum: Int, near: Int) {
        self.maximum = maximum
        self.near = near
        range = (maximum + near * 2) / (near * 2 + 1) + 1
        qbpp = Int(ceil(log2(Double(range))))
        let bpp = max(2, Int(ceil(log2(Double(maximum + 1)))))
        let fullLimit = 2 * (bpp + max(8, bpp))
        limit = fullLimit - qbpp - 1
    }

    private static let zeros: [Int] = {
        // The number of leading zero bits in a byte, 8 for zero.
        (0..<256).map { byte in byte == 0 ? 8 : (0..<8).first { byte & (0x80 >> $0) != 0 }! }
    }()

    private static let runOrder: [Int] = [
        0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3,
        4, 4, 5, 5, 6, 6, 7, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    ]

    private struct Context {
        var last: [Int]
        var current: [Int]
        let width: Int
        var runGap = 1
        var runIndex = 0
        var runK = 0
        var lastRunK = 0
        var a: [Int]
        var b = [0, 0, 0, 0]
        var n = [1, 1, 1, 1]

        init(width: Int, range: Int) {
            self.width = width
            last = [Int](repeating: 0, count: width + 3)
            current = [Int](repeating: 0, count: width + 3)
            let start = max(2, (range + 32) / 64)
            a = [start, start, start, start]
        }
    }

    func decode(_ bits: inout BitReader, width: Int, height: Int, into grid: inout [Int]) -> Bool {
        guard width > 0, height > 0 else { return false }
        var context = Context(width: width, range: range)
        for row in 0..<height {
            guard readLine(&bits, &context) else { return false }
            for column in 0..<width {
                grid[row * width + column] = context.current[column + 1]
            }
            swap(&context.last, &context.current)
        }
        return true
    }

    private func readLine(_ bits: inout BitReader, _ ctx: inout Context) -> Bool {
        var ra = ctx.last[1]
        var rb = ctx.last[1]
        var rc = ctx.last[0]
        var rx = 0
        var column = 1
        ctx.current[0] = ctx.last[1]

        repeat {
            if abs(rb - ra) > near {
                let px = min(max(ra + rb - rc, 0), maximum)
                var k = 0
                while ctx.n[1] << k < ctx.a[1] { k += 1 }
                guard let error = decodeError(&bits, limit: limit, k: k) else { return false }

                var mes: Int, meh: Int
                if error & 1 != 0 {
                    meh = (error + 1) >> 1
                    mes = -meh
                } else {
                    meh = error >> 1
                    mes = meh
                }
                if near == 0, k == 0, ctx.b[1] * 2 <= -ctx.n[1] {
                    meh = mes + 1
                    mes = -mes - 1
                    if error & 1 != 0 {
                        meh = mes
                    }
                } else {
                    mes *= near * 2 + 1
                }

                rx = px + (ra < rb ? mes : -mes)
                rx = wrapped(rx)

                ctx.a[1] += meh
                ctx.b[1] += mes
                if ctx.n[1] == 0x40 {
                    ctx.a[1] >>= 1
                    ctx.b[1] = ctx.b[1] >= 0 ? ctx.b[1] >> 1 : -((1 - ctx.b[1]) >> 1)
                    ctx.n[1] = 0x21
                } else {
                    ctx.n[1] += 1
                }
                if ctx.b[1] <= -ctx.n[1] {
                    ctx.b[1] += ctx.n[1]
                    if ctx.b[1] <= -ctx.n[1] {
                        ctx.b[1] = 1 - ctx.n[1]
                    }
                } else if ctx.b[1] > 0 {
                    ctx.b[1] -= ctx.n[1]
                    if ctx.b[1] > 0 {
                        ctx.b[1] = 0
                    }
                }

                rc = rb
                rb = ctx.last[column + 1]
            } else {
                guard let samples = runLength(&bits, &ctx, remaining: ctx.width - column + 1) else { return false }
                if samples != 0 {
                    for _ in 0..<samples {
                        guard column <= ctx.width else { return false }
                        ctx.current[column] = ra
                        column += 1
                    }
                    if column > ctx.width {
                        break
                    }
                    rc = ctx.last[column]
                    rb = ctx.last[column + 1]
                } else {
                    rc = rb
                    rb = ctx.last[column + 1]
                }

                let rctx = abs(rc - ra) <= near ? 1 : 0
                var temp = ctx.a[rctx + 2]
                if rctx == 1 {
                    temp += ctx.n[rctx + 2] >> 1
                }
                let ictx = rctx | 2
                var k = 0
                while ctx.n[rctx + 2] << k < temp { k += 1 }
                guard let error = decodeError(&bits, limit: limit - ctx.lastRunK, k: k) else { return false }

                let s = (k == 0 && (rctx == 1 || error != 0)) ? (ctx.b[ictx] * 2 < ctx.n[ictx] ? 1 : 0) : 0
                var value = error + rctx + s
                let evh: Int
                if value & 1 == 0 {
                    value /= 2
                    evh = value
                } else {
                    value = s - ((value + 1) >> 1)
                    evh = -value
                    ctx.b[ictx] += 1
                }
                value *= near * 2 + 1
                if rctx == 0 {
                    guard ra != rc else { return false }
                    rx = ra < rc ? rc + value : rc - value
                } else {
                    rx = ra + value
                }
                rx = wrapped(rx)

                ctx.a[ictx] += evh - rctx
                if ctx.n[ictx] == 0x40 {
                    ctx.a[ictx] >>= 1
                    ctx.b[ictx] = ctx.b[ictx] >= 0 ? ctx.b[ictx] >> 1 : -((1 - ctx.b[ictx]) >> 1)
                    ctx.n[ictx] = 0x21
                } else {
                    ctx.n[ictx] += 1
                }
            }

            ctx.current[column] = rx
            ra = rx
            column += 1
        } while column <= ctx.width
        return true
    }

    /// A reconstructed value brought back into 0...maximum, as JPEG-LS's modular reduction does.
    private func wrapped(_ value: Int) -> Int {
        var value = value
        if value < -near {
            value += (near * 2 + 1) * range
        } else if value > maximum + near {
            value -= (near * 2 + 1) * range
        }
        return min(max(value, 0), maximum)
    }

    /// A Golomb-coded prediction error.
    private func decodeError(_ bits: inout BitReader, limit: Int, k: Int) -> Int? {
        var count = 0
        var error = 0
        while !bits.isNegative {
            count = Self.zeros[Int(bits.top)]
            error += count
            if bits.top != 0 {
                break
            }
            bits.consume(8)
            count = 0
        }
        bits.consume(count + 1)

        if error < limit {
            if k != 0 {
                error = Int(bits.value >> UInt32(32 - k)) + (error << k)
                bits.consume(k)
            }
        } else {
            error = Int(bits.value >> UInt32(32 - qbpp)) + 1
            bits.consume(qbpp)
        }
        return error
    }

    /// The length of a run of equal values, at most `remaining`.
    private func runLength(_ bits: inout BitReader, _ ctx: inout Context, remaining: Int) -> Int? {
        var count = 0
        while true {
            var z = 0
            if bits.isNegative {
                z = Self.zeros[Int(bits.top ^ 0xFF)]
                for index in 0..<z {
                    count += ctx.runGap
                    if count <= remaining, ctx.runIndex < 31 {
                        ctx.runIndex += 1
                        ctx.runK = Self.runOrder[ctx.runIndex]
                        ctx.runGap = 1 << ctx.runK
                    }
                    if count >= remaining {
                        bits.consume(index + 1)
                        return remaining
                    }
                }
            }
            if z != 8 {
                bits.consume(z + 1)
                let samples: Int
                if ctx.runK != 0 {
                    samples = Int(bits.value >> UInt32(32 - ctx.runK)) + count
                    bits.consume(ctx.runK)
                } else {
                    samples = count
                }
                ctx.lastRunK = ctx.runK + 1
                if ctx.runIndex != 0 {
                    ctx.runIndex -= 1
                    ctx.runK = Self.runOrder[ctx.runIndex]
                    ctx.runGap = 1 << ctx.runK
                }
                return samples
            }
            bits.consume(8)
        }
    }
}
