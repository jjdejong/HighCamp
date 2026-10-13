import Foundation

public enum FITReadError: Error, Equatable {
    case notFITFile
    case truncated
    case undefinedMessage(localType: UInt8)
}

/// Reads the GPS track from a FIT activity or course file: the position, altitude and time of each
/// record message. Other messages, and developer fields, are skipped.
public enum FITActivity {
    private static let messageRecord: UInt16 = 20
    private static let fieldTimestamp: UInt8 = 253
    private static let fieldLatitude: UInt8 = 0
    private static let fieldLongitude: UInt8 = 1
    private static let fieldAltitude: UInt8 = 2
    private static let fieldEnhancedAltitude: UInt8 = 78
    private static let fitEpochOffset: Double = 631_065_600

    public static func read(_ data: Data, name: String) throws -> Track {
        var reader = Reader(bytes: [UInt8](data))
        let points = try reader.readRecordPoints()
        return Track(name: name, segments: points.isEmpty ? [] : [points])
    }
}

private struct FieldDefinition {
    let number: UInt8
    let size: Int
    let baseType: UInt8
}

private struct MessageDefinition {
    let globalNumber: UInt16
    let bigEndian: Bool
    let fields: [FieldDefinition]
    let developerFieldBytes: Int

    var dataLength: Int {
        fields.reduce(0) { $0 + $1.size } + developerFieldBytes
    }
}

private struct Reader {
    let bytes: [UInt8]
    var position = 0
    var end = 0
    var definitions: [UInt8: MessageDefinition] = [:]
    var lastTimestamp: UInt32 = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// Walks every message in the data section and collects record positions.
    mutating func readRecordPoints() throws -> [TrackPoint] {
        try readHeader()

        var points: [TrackPoint] = []
        while position < end {
            let header = try readByte()

            if header & 0x80 != 0 {
                // Compressed timestamp header: a data message whose time is a 5-bit offset.
                let local = (header >> 5) & 0x03
                let offset = UInt32(header & 0x1F)
                let previousOffset = lastTimestamp & 0x1F
                var timestamp = (lastTimestamp & ~0x1F) + offset
                if offset < previousOffset {
                    timestamp += 0x20
                }
                lastTimestamp = timestamp
                guard let definition = definitions[local] else {
                    throw FITReadError.undefinedMessage(localType: local)
                }
                if let point = try readDataMessage(definition, timestampOverride: timestamp) {
                    points.append(point)
                }
                continue
            }

            let local = header & 0x0F
            if header & 0x40 != 0 {
                definitions[local] = try readDefinition(hasDeveloperFields: header & 0x20 != 0)
                continue
            }

            guard let definition = definitions[local] else {
                throw FITReadError.undefinedMessage(localType: local)
            }
            if let point = try readDataMessage(definition, timestampOverride: nil) {
                points.append(point)
            }
        }
        return points
    }

    private mutating func readHeader() throws {
        guard bytes.count >= 14 else {
            throw FITReadError.notFITFile
        }
        let headerSize = Int(bytes[0])
        guard headerSize >= 12, bytes.count >= headerSize, Array(bytes[8..<12]) == Array(".FIT".utf8) else {
            throw FITReadError.notFITFile
        }
        let dataSize = Int(littleEndian(bytes[4..<8]))
        position = headerSize
        end = min(bytes.count, headerSize + dataSize)
    }

    private mutating func readDefinition(hasDeveloperFields: Bool) throws -> MessageDefinition {
        _ = try readByte() // reserved
        let architecture = try readByte()
        let bigEndian = architecture == 1
        let globalBytes = try readBytes(2)
        let global = bigEndian ? UInt16(globalBytes[0]) << 8 | UInt16(globalBytes[1])
                               : UInt16(globalBytes[1]) << 8 | UInt16(globalBytes[0])

        var fields: [FieldDefinition] = []
        for _ in 0..<Int(try readByte()) {
            let triple = try readBytes(3)
            fields.append(FieldDefinition(number: triple[0], size: Int(triple[1]), baseType: triple[2]))
        }

        var developerBytes = 0
        if hasDeveloperFields {
            for _ in 0..<Int(try readByte()) {
                developerBytes += Int(try readBytes(3)[1])
            }
        }
        return MessageDefinition(
            globalNumber: global,
            bigEndian: bigEndian,
            fields: fields,
            developerFieldBytes: developerBytes
        )
    }

    /// Reads one data message. Returns a track point for record messages with a position.
    private mutating func readDataMessage(_ definition: MessageDefinition, timestampOverride: UInt32?) throws -> TrackPoint? {
        let length = definition.dataLength
        guard position + length <= end else {
            throw FITReadError.truncated
        }
        let start = position
        position += length

        guard definition.globalNumber == 20 else {
            return nil
        }

        var timestamp = timestampOverride
        var latitude: Int32?
        var longitude: Int32?
        var altitude: Double?
        var offset = start
        for field in definition.fields {
            let raw = bytes[offset..<(offset + field.size)]
            offset += field.size
            switch field.number {
            case 253 where timestamp == nil:
                timestamp = UInt32(truncatingIfNeeded: unsigned(raw, bigEndian: definition.bigEndian))
            case 0:
                latitude = signed(raw, bigEndian: definition.bigEndian)
            case 1:
                longitude = signed(raw, bigEndian: definition.bigEndian)
            case 2:
                let value = unsigned(raw, bigEndian: definition.bigEndian)
                if value != 0xFFFF {
                    altitude = Double(value) / 5 - 500
                }
            case 78:
                let value = unsigned(raw, bigEndian: definition.bigEndian)
                if value != 0xFFFF_FFFF {
                    altitude = Double(value) / 5 - 500
                }
            default:
                break
            }
        }

        if let timestamp {
            lastTimestamp = timestamp
        }
        guard let latitude, let longitude, latitude != Int32.max, longitude != Int32.max else {
            return nil
        }

        let coordinate = Coordinate(
            latitude: Double(latitude) * 180 / 2_147_483_648,
            longitude: Double(longitude) * 180 / 2_147_483_648
        )
        let time = timestamp.map { Date(timeIntervalSince1970: Double($0) + 631_065_600) }
        return TrackPoint(coordinate: coordinate, elevation: altitude, time: time)
    }

    private mutating func readByte() throws -> UInt8 {
        guard position < end else {
            throw FITReadError.truncated
        }
        position += 1
        return bytes[position - 1]
    }

    /// Returns a copy, so indices start at zero whatever the position in the file.
    private mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard position + count <= end else {
            throw FITReadError.truncated
        }
        position += count
        return Array(bytes[(position - count)..<position])
    }

    private func unsigned(_ raw: ArraySlice<UInt8>, bigEndian: Bool) -> UInt64 {
        let ordered = bigEndian ? Array(raw) : Array(raw.reversed())
        return ordered.reduce(0) { $0 << 8 | UInt64($1) }
    }

    private func signed(_ raw: ArraySlice<UInt8>, bigEndian: Bool) -> Int32 {
        Int32(truncatingIfNeeded: unsigned(raw, bigEndian: bigEndian))
    }

    private func littleEndian(_ raw: ArraySlice<UInt8>) -> UInt32 {
        UInt32(truncatingIfNeeded: unsigned(raw, bigEndian: false))
    }
}
