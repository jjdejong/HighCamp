import Foundation

/// One point of a course. Elevation is optional, because routes often have none.
public struct CoursePoint: Equatable, Sendable {
    public var coordinate: Coordinate
    public var elevation: Double?

    public init(coordinate: Coordinate, elevation: Double? = nil) {
        self.coordinate = coordinate
        self.elevation = elevation
    }
}

public enum FITCourseError: Error, Equatable {
    case tooFewPoints
    case invalidSpeed
}

/// Encodes a course as a FIT file, the format Edge devices keep in `Garmin/Courses`.
///
/// Written from the public FIT protocol: a 14-byte file header, then definition and data messages
/// (file_id, course, lap and record), then a CRC-16 over the whole file.
public enum FITCourse {
    /// Edge devices show at most this many bytes of the course name.
    public static let maxNameBytes = 48

    private static let protocolVersion: UInt8 = 0x20
    private static let profileVersion: UInt16 = 2100
    private static let fitEpochOffset: Int64 = 631_065_600 // 1989-12-31 00:00:00 UTC in Unix time

    private static let messageFileID: UInt16 = 0
    private static let messageCourse: UInt16 = 31
    private static let messageLap: UInt16 = 19
    private static let messageRecord: UInt16 = 20

    private static let fileTypeCourse: UInt8 = 6
    private static let manufacturerDevelopment: UInt16 = 255
    private static let sportCycling: UInt8 = 2

    /// Builds a complete course file. Each point is timed at its distance along the course divided by
    /// `assumedSpeedKilometresPerHour`, counted from `startTime`. Edge devices pace their virtual partner by these times.
    public static func encode(name: String, points: [CoursePoint], startTime: Date = Date(), assumedSpeedKilometresPerHour: Double = 20) throws -> Data {
        guard points.count >= 2 else {
            throw FITCourseError.tooFewPoints
        }
        guard assumedSpeedKilometresPerHour > 0 else {
            throw FITCourseError.invalidSpeed
        }

        let start = fitTimestamp(startTime)
        let nameBytes = Array(truncatedName(name).utf8)
        let cumulative = cumulativeDistances(points)
        let offsets = timeOffsets(cumulative, speedKilometresPerHour: assumedSpeedKilometresPerHour)
        let end = start &+ offsets[offsets.count - 1]
        let duration = UInt32(clamping: UInt64(offsets[offsets.count - 1]) * 1000)

        var body = Writer()

        body.define(local: 0, global: messageFileID, fields: [
            Field(number: 0, size: 1, baseType: .enumeration),
            Field(number: 1, size: 2, baseType: .uint16),
            Field(number: 2, size: 2, baseType: .uint16),
            Field(number: 3, size: 4, baseType: .uint32z),
            Field(number: 4, size: 4, baseType: .uint32),
        ])
        body.byte(0)
        body.byte(fileTypeCourse)
        body.uint16(manufacturerDevelopment)
        body.uint16(1)
        body.uint32(1)
        body.uint32(start)

        body.define(local: 1, global: messageCourse, fields: [
            Field(number: 4, size: 1, baseType: .enumeration),
            Field(number: 5, size: UInt8(nameBytes.count + 1), baseType: .string),
        ])
        body.byte(1)
        body.byte(sportCycling)
        body.append(nameBytes)
        body.byte(0)

        body.define(local: 2, global: messageLap, fields: [
            Field(number: 254, size: 2, baseType: .uint16),
            Field(number: 253, size: 4, baseType: .uint32),
            Field(number: 2, size: 4, baseType: .uint32),
            Field(number: 3, size: 4, baseType: .sint32),
            Field(number: 4, size: 4, baseType: .sint32),
            Field(number: 5, size: 4, baseType: .sint32),
            Field(number: 6, size: 4, baseType: .sint32),
            Field(number: 7, size: 4, baseType: .uint32),
            Field(number: 8, size: 4, baseType: .uint32),
            Field(number: 9, size: 4, baseType: .uint32),
            Field(number: 25, size: 1, baseType: .enumeration),
        ])
        body.byte(2)
        body.uint16(0)
        body.uint32(end)
        body.uint32(start)
        body.int32(semicircles(points[0].coordinate.latitude))
        body.int32(semicircles(points[0].coordinate.longitude))
        body.int32(semicircles(points[points.count - 1].coordinate.latitude))
        body.int32(semicircles(points[points.count - 1].coordinate.longitude))
        // Elapsed and timer time are equal: the course has no pauses. Both are in milliseconds (scale 1000).
        body.uint32(duration)
        body.uint32(duration)
        body.uint32(centimetres(cumulative[cumulative.count - 1]))
        body.byte(sportCycling)

        body.define(local: 3, global: messageRecord, fields: [
            Field(number: 253, size: 4, baseType: .uint32),
            Field(number: 0, size: 4, baseType: .sint32),
            Field(number: 1, size: 4, baseType: .sint32),
            Field(number: 5, size: 4, baseType: .uint32),
            Field(number: 2, size: 2, baseType: .uint16),
        ])
        for (index, point) in points.enumerated() {
            body.byte(3)
            body.uint32(start &+ offsets[index])
            body.int32(semicircles(point.coordinate.latitude))
            body.int32(semicircles(point.coordinate.longitude))
            body.uint32(centimetres(cumulative[index]))
            body.uint16(altitude(point.elevation))
        }

        var file = Writer()
        file.byte(14)
        file.byte(protocolVersion)
        file.uint16(profileVersion)
        file.uint32(UInt32(body.bytes.count))
        file.append(Array(".FIT".utf8))
        file.uint16(FITChecksum.crc16(file.bytes))
        file.append(body.bytes)
        file.uint16(FITChecksum.crc16(file.bytes))
        return Data(file.bytes)
    }

    /// A file name for the course on the device, such as `Lac_du_Bourget.fit`.
    public static func fileName(for name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let safe = String(String.UnicodeScalarView(name.unicodeScalars.map { allowed.contains($0) ? $0 : "_" }))
        let trimmed = String(safe.prefix(40))
        return (trimmed.isEmpty ? "Course" : trimmed) + ".fit"
    }

    /// The name as it will be stored: trimmed, and cut to `maxNameBytes` bytes on a character boundary.
    public static func truncatedName(_ name: String) -> String {
        var result = ""
        for character in name.trimmingCharacters(in: .whitespacesAndNewlines) {
            guard result.utf8.count + String(character).utf8.count <= maxNameBytes else { break }
            result.append(character)
        }
        return result.isEmpty ? "Course" : result
    }

    // MARK: Field values

    private static func fitTimestamp(_ date: Date) -> UInt32 {
        UInt32(clamping: Int64(date.timeIntervalSince1970.rounded()) - fitEpochOffset)
    }

    /// FIT stores angles as signed 32-bit semicircles.
    private static func semicircles(_ degrees: Double) -> Int32 {
        Int32(clamping: Int((degrees * 2_147_483_648.0 / 180.0).rounded()))
    }

    private static func centimetres(_ meters: Double) -> UInt32 {
        UInt32(clamping: Int((meters * 100).rounded()))
    }

    /// FIT stores altitude as (metres + 500) * 5 in a uint16. 0xFFFF means no value.
    private static func altitude(_ elevation: Double?) -> UInt16 {
        guard let elevation else { return 0xFFFF }
        let scaled = ((elevation + 500) * 5).rounded()
        return UInt16(clamping: Int(max(0, min(scaled, 65_534))))
    }

    /// Whole seconds from the start to each point, at a constant speed.
    private static func timeOffsets(_ cumulative: [Double], speedKilometresPerHour: Double) -> [UInt32] {
        let metresPerSecond = speedKilometresPerHour * 1000 / 3600
        return cumulative.map { UInt32(min(($0 / metresPerSecond).rounded(), Double(UInt32.max))) }
    }

    private static func cumulativeDistances(_ points: [CoursePoint]) -> [Double] {
        var total = 0.0
        var result = [0.0]
        for (previous, next) in zip(points, points.dropFirst()) {
            total += Geodesy.distance(from: previous.coordinate, to: next.coordinate)
            result.append(total)
        }
        return result
    }
}

public extension Route {
    /// The route's points as course points.
    var coursePoints: [CoursePoint] {
        points.map { CoursePoint(coordinate: $0.coordinate, elevation: $0.elevation) }
    }
}

public extension Track {
    /// Every point of every segment, in order, as course points.
    var coursePoints: [CoursePoint] {
        segments.flatMap { segment in
            segment.map { CoursePoint(coordinate: $0.coordinate, elevation: $0.elevation) }
        }
    }
}

/// FIT field base types needed for the course messages.
private enum BaseType: UInt8 {
    case enumeration = 0x00
    case uint16 = 0x84
    case uint32 = 0x86
    case sint32 = 0x85
    case uint32z = 0x8C
    case string = 0x07
}

private struct Field {
    let number: UInt8
    let size: UInt8
    let baseType: BaseType
}

private struct Writer {
    private(set) var bytes: [UInt8] = []

    mutating func byte(_ value: UInt8) {
        bytes.append(value)
    }

    mutating func append(_ more: [UInt8]) {
        bytes.append(contentsOf: more)
    }

    mutating func uint16(_ value: UInt16) {
        littleEndian(UInt64(value), count: 2)
    }

    mutating func uint32(_ value: UInt32) {
        littleEndian(UInt64(value), count: 4)
    }

    mutating func int32(_ value: Int32) {
        uint32(UInt32(bitPattern: value))
    }

    /// Definition message: header byte, reserved byte, architecture (0 = little endian), global number, fields.
    mutating func define(local: UInt8, global: UInt16, fields: [Field]) {
        byte(0x40 | local)
        byte(0)
        byte(0)
        uint16(global)
        byte(UInt8(fields.count))
        for field in fields {
            byte(field.number)
            byte(field.size)
            byte(field.baseType.rawValue)
        }
    }

    private mutating func littleEndian(_ value: UInt64, count: Int) {
        for shift in 0..<count {
            bytes.append(UInt8((value >> (8 * UInt64(shift))) & 0xFF))
        }
    }
}

/// The CRC-16 used by FIT files: CRC-16/ARC (reflected polynomial 0xA001, initial value 0).
enum FITChecksum {
    static func crc16<S: Sequence>(_ bytes: S) -> UInt16 where S.Element == UInt8 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                crc = crc & 1 != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1
            }
        }
        return crc
    }
}
