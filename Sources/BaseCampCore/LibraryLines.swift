import CryptoKit
import Foundation

/// The lines of a library's tracks and routes (track points, routes' leg shapes), which the library file keeps apart:
/// one small binary file per item, in a folder next to it (see `LibraryFile`). A save then writes only the lines that
/// changed, and the library file stays small however many points the tracks have.
///
/// A file is named after its item and a hash of its contents, so a changed line is a new file: the library file names
/// the files it uses, and the old ones are removed only once it is written.
///
/// Layout, little-endian: "HCLN", format version (u8), kind (u8: 1 track, 2 route), u32 number of lines, and for each
/// line a u32 point count and the points. A point is its latitude and longitude (f64), a byte with a bit for each
/// optional value present, and those values in order: for a track elevation, time (seconds since 2001, Date's own
/// measure, so times come back exactly), heart rate, cadence, power, temperature, each an f64; for a route elevation
/// (f64) and name (u32 byte count, UTF-8).
enum LibraryLines: Equatable {
    case track([[TrackPoint]])
    case route([[RoutePoint]])

    enum ReadError: Error, Equatable {
        case damaged(String)
    }

    private static let magic = Array("HCLN".utf8)
    private static let formatVersion: UInt8 = 1

    /// Whether there is nothing to keep: no file is written for an item without lines.
    var isEmpty: Bool {
        switch self {
        case .track(let lines): lines.allSatisfy(\.isEmpty)
        case .route(let lines): lines.allSatisfy(\.isEmpty)
        }
    }

    /// The file name for these lines of item `id`: the item and a hash of the contents.
    static func fileName(for id: UUID, data: Data) -> String {
        let hash = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(id.uuidString)-\(hash).line"
    }

    // MARK: Writing

    func encoded() -> Data {
        var out = Data()
        out.append(contentsOf: Self.magic)
        out.append(Self.formatVersion)
        switch self {
        case .track(let lines):
            out.append(1)
            Self.append(UInt32(lines.count), to: &out)
            for line in lines {
                Self.append(UInt32(line.count), to: &out)
                for point in line {
                    Self.append(point.coordinate, to: &out)
                    Self.append(
                        point.elevation, point.time?.timeIntervalSinceReferenceDate, point.heartRate, point.cadence,
                        point.power, point.temperature, to: &out
                    )
                }
            }
        case .route(let lines):
            out.append(2)
            Self.append(UInt32(lines.count), to: &out)
            for line in lines {
                Self.append(UInt32(line.count), to: &out)
                for point in line {
                    Self.append(point.coordinate, to: &out)
                    let name = point.name.map { Data($0.utf8) }
                    out.append((point.elevation == nil ? 0 : 1) | (name == nil ? 0 : 2))
                    if let elevation = point.elevation { Self.append(elevation.bitPattern, to: &out) }
                    if let name {
                        Self.append(UInt32(name.count), to: &out)
                        out.append(name)
                    }
                }
            }
        }
        return out
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to out: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
    }

    private static func append(_ coordinate: Coordinate, to out: inout Data) {
        append(coordinate.latitude.bitPattern, to: &out)
        append(coordinate.longitude.bitPattern, to: &out)
    }

    /// The presence byte, then the values present. Six values as arguments, not an array: this runs for every point.
    private static func append(
        _ a: Double?, _ b: Double?, _ c: Double?, _ d: Double?, _ e: Double?, _ f: Double?, to out: inout Data
    ) {
        var present: UInt8 = 0
        if a != nil { present |= 1 }
        if b != nil { present |= 2 }
        if c != nil { present |= 4 }
        if d != nil { present |= 8 }
        if e != nil { present |= 16 }
        if f != nil { present |= 32 }
        out.append(present)
        if let a { append(a.bitPattern, to: &out) }
        if let b { append(b.bitPattern, to: &out) }
        if let c { append(c.bitPattern, to: &out) }
        if let d { append(d.bitPattern, to: &out) }
        if let e { append(e.bitPattern, to: &out) }
        if let f { append(f.bitPattern, to: &out) }
    }

    // MARK: Reading

    init(_ data: Data) throws {
        var reader = Reader(bytes: [UInt8](data))
        guard Array(try reader.bytes(4)) == Self.magic else { throw ReadError.damaged("not a line file") }
        guard try reader.u8() == Self.formatVersion else { throw ReadError.damaged("unknown line file version") }
        let kind = try reader.u8()
        let count = try reader.count()
        switch kind {
        case 1:
            var lines: [[TrackPoint]] = []
            lines.reserveCapacity(count)
            for _ in 0..<count {
                let points = try reader.count()
                var line: [TrackPoint] = []
                line.reserveCapacity(points)
                for _ in 0..<points {
                    let coordinate = try reader.coordinate()
                    let present = try reader.u8()
                    func value(_ bit: Int) throws -> Double? {
                        present & (1 << bit) == 0 ? nil : try reader.f64()
                    }
                    line.append(TrackPoint(
                        coordinate: coordinate, elevation: try value(0),
                        time: try value(1).map(Date.init(timeIntervalSinceReferenceDate:)),
                        heartRate: try value(2), cadence: try value(3), power: try value(4), temperature: try value(5)
                    ))
                }
                lines.append(line)
            }
            self = .track(lines)
        case 2:
            var lines: [[RoutePoint]] = []
            lines.reserveCapacity(count)
            for _ in 0..<count {
                let points = try reader.count()
                var line: [RoutePoint] = []
                line.reserveCapacity(points)
                for _ in 0..<points {
                    let coordinate = try reader.coordinate()
                    let present = try reader.u8()
                    let elevation = present & 1 == 0 ? nil : try reader.f64()
                    var name: String?
                    if present & 2 != 0 {
                        let length = try reader.count()
                        name = String(decoding: try reader.bytes(length), as: UTF8.self)
                    }
                    line.append(RoutePoint(name: name, coordinate: coordinate, elevation: elevation))
                }
                lines.append(line)
            }
            self = .route(lines)
        default:
            throw ReadError.damaged("unknown kind of line file")
        }
        guard reader.isAtEnd else { throw ReadError.damaged("line file too long") }
    }

    private struct Reader {
        let bytes: [UInt8]
        var position = 0

        var isAtEnd: Bool { position == bytes.count }

        mutating func bytes(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, count <= bytes.count - position else { throw ReadError.damaged("line file cut short") }
            defer { position += count }
            return bytes[position..<(position + count)]
        }

        mutating func u8() throws -> UInt8 {
            try bytes(1).first!
        }

        mutating func u64() throws -> UInt64 {
            try load(UInt64.self)
        }

        private mutating func load<T: FixedWidthInteger>(_: T.Type) throws -> T {
            let size = MemoryLayout<T>.size
            guard size <= bytes.count - position else { throw ReadError.damaged("line file cut short") }
            defer { position += size }
            return T(littleEndian: bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: position, as: T.self) })
        }

        /// A u32 count, no larger than what could still follow: a damaged count fails here, not in a huge allocation.
        mutating func count() throws -> Int {
            let value = Int(try load(UInt32.self))
            guard value <= bytes.count - position else { throw ReadError.damaged("line file cut short") }
            return value
        }

        mutating func f64() throws -> Double {
            Double(bitPattern: try u64())
        }

        mutating func coordinate() throws -> Coordinate {
            Coordinate(latitude: try f64(), longitude: try f64())
        }
    }
}
