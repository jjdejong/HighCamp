import Foundation

/// Reads the saved locations of a Garmin Edge, kept in `Garmin/Locations/Locations.fit` (FIT file type 8), as
/// waypoints. Written from the public FIT protocol: each location is a message 29 with its name (field 0), position
/// (1 and 2, semicircles), altitude (4, metres + 500 times 5), description (6) and time (253). Other messages, and
/// developer fields, are skipped.
public enum FITLocations {
    public static func read(_ data: Data) throws -> [Waypoint] {
        try FITMessages.read(data).filter { $0.global == 29 }.compactMap { message in
            guard let latitude = message.signed(1), let longitude = message.signed(2),
                  latitude != Int64(Int32.max), longitude != Int64(Int32.max) else { return nil }
            let coordinate = Coordinate(
                latitude: Double(latitude) * 180 / 2_147_483_648, longitude: Double(longitude) * 180 / 2_147_483_648
            )
            guard coordinate.isValid else { return nil }
            let altitude = message.unsigned(4).flatMap { $0 == 0xFFFF ? nil : Double($0) / 5 - 500 }
            let time = message.unsigned(253).flatMap { $0 == 0xFFFF_FFFF ? nil : Date(timeIntervalSince1970: Double($0) + 631_065_600) }
            let description = message.string(6)
            return Waypoint(
                name: message.string(0) ?? "Location", coordinate: coordinate, elevation: altitude, time: time,
                comment: description
            )
        }
    }
}

/// The data messages of a FIT file, with each field's bytes, for messages read field by field.
struct FITMessages {
    let global: UInt16
    let bigEndian: Bool
    let fields: [UInt8: [UInt8]]

    func unsigned(_ number: UInt8) -> UInt64? {
        guard let bytes = fields[number], !bytes.isEmpty, bytes.count <= 8 else { return nil }
        return (bigEndian ? bytes : bytes.reversed()).reduce(0) { $0 << 8 | UInt64($1) }
    }

    func signed(_ number: UInt8) -> Int64? {
        guard let value = unsigned(number), let size = fields[number]?.count else { return nil }
        let shift = UInt64(64 - 8 * size)
        return Int64(bitPattern: value << shift) >> Int64(shift)
    }

    func string(_ number: UInt8) -> String? {
        guard let bytes = fields[number] else { return nil }
        let text = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func read(_ data: Data) throws -> [FITMessages] {
        let bytes = [UInt8](data)
        guard bytes.count >= 14 else { throw FITReadError.notFITFile }
        let headerSize = Int(bytes[0])
        guard headerSize >= 12, bytes.count >= headerSize, Array(bytes[8..<12]) == Array(".FIT".utf8) else {
            throw FITReadError.notFITFile
        }
        let size = Int(bytes[4]) | Int(bytes[5]) << 8 | Int(bytes[6]) << 16 | Int(bytes[7]) << 24
        let end = min(bytes.count, headerSize + size)
        var position = headerSize
        var definitions: [UInt8: (global: UInt16, bigEndian: Bool, fields: [(number: UInt8, size: Int)], developer: Int)] = [:]
        var messages: [FITMessages] = []
        func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard position + count <= end else { throw FITReadError.truncated }
            defer { position += count }
            return bytes[position..<(position + count)]
        }
        while position < end {
            let header = try take(1).first!
            let local = header & 0x80 != 0 ? (header >> 5) & 0x03 : header & 0x0F
            if header & 0xC0 == 0x40 {
                let fixed = Array(try take(5))
                let bigEndian = fixed[1] == 1
                let global = bigEndian ? UInt16(fixed[2]) << 8 | UInt16(fixed[3]) : UInt16(fixed[3]) << 8 | UInt16(fixed[2])
                var fields: [(number: UInt8, size: Int)] = []
                for _ in 0..<Int(fixed[4]) {
                    let triple = Array(try take(3))
                    fields.append((triple[0], Int(triple[1])))
                }
                var developer = 0
                if header & 0x20 != 0 {
                    for _ in 0..<Int(try take(1).first!) {
                        developer += Int(Array(try take(3))[1])
                    }
                }
                definitions[local] = (global, bigEndian, fields, developer)
                continue
            }
            guard let definition = definitions[local] else { throw FITReadError.undefinedMessage(localType: local) }
            var fields: [UInt8: [UInt8]] = [:]
            for field in definition.fields {
                fields[field.number] = Array(try take(field.size))
            }
            _ = try take(definition.developer)
            messages.append(FITMessages(global: definition.global, bigEndian: definition.bigEndian, fields: fields))
        }
        return messages
    }
}
