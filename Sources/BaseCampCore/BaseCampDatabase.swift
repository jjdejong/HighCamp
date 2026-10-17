import Foundation

/// Reads the library BaseCamp keeps for itself, with its lists and list folders: the database folder (`Database/4.8`
/// in a `.bclibrary`, or in ~/Library/Application Support/Garmin/BaseCamp) holding `AllData.gdb` (waypoints, routes,
/// tracks), `FolderData.gfi` (lists and folders) and `TrackSegments` (each track's heights and times). Nothing there is
/// written.
///
/// The layout was worked out from the files themselves; no Garmin code was used. `AllData.gdb` is close to MapSource's
/// GDB format as GPSBabel describes it: a six-byte magic, then records of a 32-bit length, a type letter and that many
/// bytes. Numbers are little-endian, positions are semicircles, times are seconds since 1970, a string ends with a
/// NUL, and an optional value is a flag byte, 1 when the value follows and 0 when it does not.
public enum BaseCampDatabase {
    public enum ReadError: LocalizedError, Equatable {
        /// The folder holds no BaseCamp database.
        case noDatabase
        /// A file is shorter than its records say, or not a BaseCamp file at all.
        case damaged(String)

        public var errorDescription: String? {
            switch self {
            case .noDatabase: "The folder holds no BaseCamp library (no AllData.gdb)."
            case .damaged(let file): "\(file) could not be read: it is damaged or not from BaseCamp."
            }
        }
    }

    /// What was read: the library, with BaseCamp's lists and folders, and the items that could not be read.
    public struct Contents: Sendable {
        public var library: Library
        public var unreadable: Int
    }

    /// The database folder for what the user chose: the folder itself when it holds `AllData.gdb`, else the newest
    /// version folder in it or in its `Database` folder (a `.bclibrary`, or BaseCamp's own folder).
    public static func databaseFolder(for url: URL) -> URL? {
        let files = FileManager.default
        func holdsDatabase(_ folder: URL) -> Bool {
            files.fileExists(atPath: folder.appendingPathComponent("AllData.gdb").path)
        }
        func newestVersion(in folder: URL) -> URL? {
            let names = (try? files.contentsOfDirectory(atPath: folder.path)) ?? []
            return names.filter { holdsDatabase(folder.appendingPathComponent($0)) }
                .max { $0.compare($1, options: .numeric) == .orderedAscending }
                .map { folder.appendingPathComponent($0) }
        }
        if holdsDatabase(url) { return url }
        return newestVersion(in: url) ?? newestVersion(in: url.appendingPathComponent("Database"))
    }

    /// Reads the database in `folder` (see `databaseFolder(for:)`). Smart lists, which BaseCamp fills itself, are left
    /// out; so are the route points BaseCamp keeps as hidden waypoints.
    public static func read(_ folder: URL) throws -> Contents {
        guard let all = try? [UInt8](Data(contentsOf: folder.appendingPathComponent("AllData.gdb"))) else {
            throw ReadError.noDatabase
        }
        var library = Library()
        var unreadable = 0
        var places: [[UInt8]: Coordinate] = [:]
        var routeRecords: [Record] = []
        for record in try records(all, file: "AllData.gdb") {
            var reader = ByteReader(all, record.range)
            switch record.type {
            case UInt8(ascii: "W"):
                guard let stored = try? waypoint(&reader) else {
                    unreadable += 1
                    continue
                }
                places[stored.name] = stored.coordinate
                if let waypoint = stored.waypoint {
                    library.waypoints.append(waypoint)
                }
            case UInt8(ascii: "T"):
                if let track = try? track(&reader, segments: folder.appendingPathComponent("TrackSegments")) {
                    library.tracks.append(track)
                } else {
                    unreadable += 1
                }
            case UInt8(ascii: "R"):
                routeRecords.append(record)
            default:
                break
            }
        }
        // Routes name their points, which are waypoints, so they are read once every waypoint is known.
        for record in routeRecords {
            if let route = route(all, record.range, places: places) {
                library.routes.append(route)
            } else {
                unreadable += 1
            }
        }
        if let lists = try? [UInt8](Data(contentsOf: folder.appendingPathComponent("FolderData.gfi"))) {
            try addLists(from: lists, to: &library)
        }
        return Contents(library: library, unreadable: unreadable)
    }

    // MARK: Records

    struct Record {
        var type: UInt8
        var range: Range<Int>
    }

    /// The records of a database file: after the magic, a version record ('D'), a build record ('A') followed by the
    /// program's name ("BaseCamp"), then the data records.
    static func records(_ bytes: [UInt8], file: String) throws -> [Record] {
        guard bytes.count > 6 else { throw ReadError.damaged(file) }
        var reader = ByteReader(bytes, 6..<bytes.count)
        var found: [Record] = []
        do {
            while !reader.isAtEnd {
                let length = Int(try reader.u32())
                let type = try reader.u8()
                let start = reader.offset
                try reader.skip(length)
                switch type {
                case UInt8(ascii: "D"):
                    break
                case UInt8(ascii: "A"):
                    _ = try reader.string()
                default:
                    found.append(Record(type: type, range: start..<reader.offset))
                }
            }
        } catch {
            throw ReadError.damaged(file)
        }
        return found
    }

    // MARK: Waypoints

    struct StoredWaypoint {
        var name: [UInt8]
        var coordinate: Coordinate
        /// The waypoint as the user sees it; nil for the route points BaseCamp keeps as hidden waypoints.
        var waypoint: Waypoint?
    }

    /// A waypoint record. Its class is 0 for the user's waypoints; the route points have others, and only their name
    /// and place are read.
    static func waypoint(_ reader: inout ByteReader) throws -> StoredWaypoint {
        let name = try reader.stringBytes()
        let kind = try reader.i32()
        let coordinate = try reader.coordinate()
        guard kind == 0 else { return StoredWaypoint(name: name, coordinate: coordinate) }
        let notes = try reader.string()
        let proximity = try reader.optional { try $0.f64() }
        _ = try reader.i32() // display
        let symbol = try reader.i32()
        let street = try reader.string(), city = try reader.string(), state = try reader.string()
        let country = try reader.string(), postalCode = try reader.string()
        // Where the waypoint came from in a map, when it did: 23 bytes.
        if try reader.u8() == 1 {
            try reader.skip(23)
        }
        guard try reader.u8() == 0 else { throw ReadError.damaged("AllData.gdb") }
        let elevation = try reader.optional { try $0.f64() }
        _ = try reader.optional { try $0.f64() } // depth
        let links = try reader.strings()
        _ = try reader.optional { try $0.f64() } // temperature
        let modified = try reader.optional { try $0.u32() }
        try reader.skip(6)
        var phones: [String] = []
        for _ in 0..<(try reader.count()) {
            phones.append(try reader.string())
            _ = try reader.u8()
        }
        let created = try reader.optional { try $0.u32() }

        let comment = ([notes] + links).filter { !$0.isEmpty }.joined(separator: "\n")
        let address = WaypointAddress(street: street.nonEmpty, city: city.nonEmpty, state: state.nonEmpty,
                                      postalCode: postalCode.nonEmpty, country: country.nonEmpty, phone: phones.first?.nonEmpty)
        let waypoint = Waypoint(
            name: String(decoding: name, as: UTF8.self),
            coordinate: coordinate,
            elevation: elevation,
            time: (created ?? modified).map { Date(timeIntervalSince1970: TimeInterval($0)) },
            comment: comment.nonEmpty,
            symbol: MapSourceSymbols.name(for: Int(symbol)),
            proximity: proximity.flatMap { $0 > 0 ? $0 : nil },
            address: address == WaypointAddress() ? nil : address
        )
        return StoredWaypoint(name: name, coordinate: coordinate, waypoint: waypoint)
    }

    // MARK: Tracks

    /// A track record: its header, then its line as segments of blocks of up to 100 points, each block starting with
    /// the point the one before ended on, then the number of points and the name of its file in `TrackSegments`.
    static func track(_ reader: inout ByteReader, segments folder: URL) throws -> Track {
        let name = try reader.string()
        _ = try reader.i32()
        _ = try reader.u8() // display
        // Indexes into BaseCamp's 16 colours, from 1; 0 is the default colour.
        let colour = Int(try reader.i32())
        _ = try reader.strings() // links
        _ = try reader.string() // notes
        _ = try reader.f64()
        _ = try reader.optional { try $0.f64() }
        _ = try reader.u8()
        try reader.skip(16) // bounds
        _ = try reader.optional { try $0.f64() }
        _ = try reader.f64() // length
        _ = try reader.optional { try $0.u32() }
        var segments: [[Coordinate]] = []
        for _ in 0..<(try reader.count()) {
            var points: [Coordinate] = []
            for block in 0..<(try reader.count()) {
                _ = try reader.u8()
                try reader.skip(16) // bounds
                let count = try reader.count()
                for index in 0..<count {
                    let point = try reader.coordinate()
                    if index == 0, block > 0, point == points.last { continue }
                    points.append(point)
                }
            }
            segments.append(points)
        }
        let count = Int(try reader.u32())
        let file = try reader.string()

        let total = segments.reduce(0) { $0 + $1.count }
        let details = total == count ? pointDetails(folder.appendingPathComponent(file), count: count) : nil
        var next = 0
        let trackSegments = segments.map { points in
            points.map { coordinate in
                defer { next += 1 }
                let detail = details?[next]
                return TrackPoint(coordinate: coordinate, elevation: detail?.elevation, time: detail?.time)
            }
        }
        return Track(name: name, segments: trackSegments, color: colour > 0 ? GarminColour.color(at: colour - 1) : nil)
    }

    /// The height and time of each point of a track, from its file in `TrackSegments`: after the header, the number of
    /// points, then for each an optional height, an optional time and 15 bytes BaseCamp leaves empty. Nil when there
    /// is no file, or it does not hold `count` points.
    static func pointDetails(_ url: URL, count: Int) -> [(elevation: Double?, time: Date?)]? {
        guard let bytes = try? [UInt8](Data(contentsOf: url)), bytes.count > 6 else { return nil }
        var reader = ByteReader(bytes, 6..<bytes.count)
        do {
            // The header: 'D' and 'A' records, then the program's name.
            for _ in 0..<2 {
                try reader.skip(Int(try reader.u32()) + 1)
            }
            _ = try reader.string()
            guard try reader.u32() == count else { return nil }
            var details: [(elevation: Double?, time: Date?)] = []
            details.reserveCapacity(count)
            for _ in 0..<count {
                let elevation = try reader.optional { try $0.f64() }
                let time = try reader.optional { try $0.u32() }
                try reader.skip(15)
                details.append((elevation.flatMap { (-1000...10000).contains($0) ? $0 : nil },
                                time.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }))
            }
            return reader.isAtEnd ? details : nil
        } catch {
            return nil
        }
    }

    // MARK: Routes

    /// What starts each route point in a route record, after its name and class: an empty country and four bytes
    /// BaseCamp always writes.
    private static let routePointMark: [UInt8] = [0, 3, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF]
    /// The classes BaseCamp gives route points (a user's waypoint used as one keeps class 0).
    private static let routePointClasses: Set<Int32> = [0, 8, 9, 10, 11, 12]

    /// A route record: its name, a byte and the number of route points, then each route point (a waypoint, by name)
    /// with the leg to the next one. A leg is BaseCamp's calculated line, kept in steps, each with its own list of
    /// points; every list is followed by the box round its points, which tells the lists from the rest. The points are
    /// found by their names, from the longest that fits, as they are not all laid out alike.
    static func route(_ bytes: [UInt8], _ range: Range<Int>, places: [[UInt8]: Coordinate]) -> Route? {
        var reader = ByteReader(bytes, range)
        guard let name = try? reader.string(), (try? reader.u8()) != nil, let declared = try? reader.count(),
              declared > 0 else { return nil }
        let points = routePoints(bytes, reader.offset..<range.upperBound, places: places)
        guard points.count == declared else { return nil }
        let stops = points.map { point in
            RouteStop(name: String(decoding: point.name, as: UTF8.self), coordinate: point.coordinate)
        }
        let legs = points.indices.dropLast().map { index in
            let start = points[index].coordinate, end = points[index + 1].coordinate
            var shape: [Coordinate] = []
            for list in pointLists(bytes, points[index].body.lowerBound..<points[index + 1].start) {
                for point in list where point != shape.last {
                    shape.append(point)
                }
            }
            let inner = shape.filter { $0 != start && $0 != end }
            return RouteLeg(shape: inner.map { RoutePoint(coordinate: $0) }, method: inner.isEmpty ? .direct : .imported)
        }
        return Route(name: name, stops: stops, legs: legs)
    }

    struct RoutePart {
        var name: [UInt8]
        var coordinate: Coordinate
        /// Where its name starts, and where what follows its header starts.
        var start: Int
        var body: Range<Int>
    }

    static func routePoints(_ bytes: [UInt8], _ range: Range<Int>, places: [[UInt8]: Coordinate]) -> [RoutePart] {
        var found: [RoutePart] = []
        var at = range.lowerBound
        while let mark = firstIndex(of: routePointMark, in: bytes, from: at, before: range.upperBound) {
            at = mark + 1
            // The name's NUL, then the 32-bit class, then the mark.
            let nameEnd = mark - 5
            guard nameEnd > range.lowerBound, bytes[nameEnd] == 0,
                  routePointClasses.contains(int32(bytes, at: mark - 4)) else { continue }
            var start = nameEnd
            while start > max(range.lowerBound, nameEnd - 1024), bytes[start - 1] != 0 {
                start -= 1
            }
            // The longest name that is a waypoint's: what comes before a name is not always a NUL.
            for candidate in start..<nameEnd {
                let name = Array(bytes[candidate..<nameEnd])
                if let coordinate = places[name] {
                    found.append(RoutePart(name: name, coordinate: coordinate, start: candidate, body: mark..<range.upperBound))
                    break
                }
            }
        }
        // Each point's part ends where the next one's name starts.
        for index in found.indices.dropLast() {
            found[index].body = found[index].body.lowerBound..<found[index + 1].start
        }
        return found
    }

    /// The lists of points in `range`: a 32-bit count, the points, a zero byte and the box round them (north, east,
    /// south, west), which must fit the points exactly.
    static func pointLists(_ bytes: [UInt8], _ range: Range<Int>) -> [[Coordinate]] {
        var lists: [[Coordinate]] = []
        var at = range.lowerBound
        while at + 4 <= range.upperBound {
            let count = Int(int32(bytes, at: at))
            let boxStart = at + 4 + 8 * count
            if count > 0, count <= 50_000, boxStart + 17 <= range.upperBound, bytes[boxStart] == 0 {
                var north = Int32.min, east = Int32.min, south = Int32.max, west = Int32.max
                for index in 0..<count {
                    let latitude = int32(bytes, at: at + 4 + 8 * index), longitude = int32(bytes, at: at + 8 + 8 * index)
                    north = max(north, latitude); south = min(south, latitude)
                    east = max(east, longitude); west = min(west, longitude)
                }
                if (north, east, south, west) == (int32(bytes, at: boxStart + 1), int32(bytes, at: boxStart + 5),
                                                  int32(bytes, at: boxStart + 9), int32(bytes, at: boxStart + 13)) {
                    lists.append((0..<count).map { index in
                        semicircles(int32(bytes, at: at + 4 + 8 * index), int32(bytes, at: at + 8 + 8 * index))
                    })
                    at = boxStart + 17
                    continue
                }
            }
            at += 1
        }
        return lists
    }

    // MARK: Lists and folders

    /// `FolderData.gfi`: folders ('F': id, name, parent, then what they hold), lists ('I': id, name, kind, folder) and
    /// what each list holds ('W', 'R', 'T': list id and the item's name). BaseCamp's top folder, "My Collection", has
    /// id -1; its lists and folders go at the top of the library.
    static func addLists(from bytes: [UInt8], to library: inout Library) throws {
        var folders: [Int32: (name: String, parent: Int32)] = [:]
        var lists: [Int32: (name: String, folder: Int32)] = [:]
        var members: [Int32: [CollectionItem]] = [:]
        let waypoints = Dictionary(library.waypoints.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
        let routes = Dictionary(library.routes.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
        let tracks = Dictionary(library.tracks.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
        for record in try records(bytes, file: "FolderData.gfi") {
            var reader = ByteReader(bytes, record.range)
            guard let id = try? reader.i32(), let name = try? reader.string() else { continue }
            switch record.type {
            case UInt8(ascii: "F"):
                if let parent = try? reader.i32(), id != -1 {
                    folders[id] = (name, parent)
                }
            case UInt8(ascii: "I"):
                // Kind 0 is a list the user fills; the others are smart lists.
                if let kind = try? reader.i32(), kind == 0, let folder = try? reader.i32() {
                    lists[id] = (name, folder)
                }
            case UInt8(ascii: "W"):
                if let item = waypoints[name] { members[id, default: []].append(.waypoint(item)) }
            case UInt8(ascii: "R"):
                if let item = routes[name] { members[id, default: []].append(.route(item)) }
            case UInt8(ascii: "T"):
                if let item = tracks[name] { members[id, default: []].append(.track(item)) }
            default:
                break
            }
        }
        let folderIDs = folders.mapValues { _ in UUID() }
        library.folders += folders.sorted { $0.key < $1.key }.map { id, folder in
            ListFolder(id: folderIDs[id]!, name: folder.name, parentID: folderIDs[folder.parent])
        }
        library.collections += lists.sorted { $0.key < $1.key }.map { id, list in
            LibraryCollection(name: list.name, items: members[id] ?? [], folderID: folderIDs[list.folder])
        }
    }

    // MARK: Bytes

    static func int32(_ bytes: [UInt8], at offset: Int) -> Int32 {
        Int32(bitPattern: UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
              | UInt32(bytes[offset + 3]) << 24)
    }

    static func semicircles(_ latitude: Int32, _ longitude: Int32) -> Coordinate {
        Coordinate(latitude: Double(latitude) * 180 / 2_147_483_648, longitude: Double(longitude) * 180 / 2_147_483_648)
    }

    private static func firstIndex(of pattern: [UInt8], in bytes: [UInt8], from start: Int, before end: Int) -> Int? {
        guard let first = pattern.first, end - start >= pattern.count else { return nil }
        var index = start
        while index <= end - pattern.count {
            if bytes[index] == first, bytes[index..<(index + pattern.count)].elementsEqual(pattern) {
                return index
            }
            index += 1
        }
        return nil
    }
}

/// Reads little-endian values from a part of a file, throwing when the part is too short.
struct ByteReader {
    private let bytes: [UInt8]
    private let end: Int
    private(set) var offset: Int

    init(_ bytes: [UInt8], _ range: Range<Int>) {
        self.bytes = bytes
        self.offset = range.lowerBound
        self.end = min(range.upperBound, bytes.count)
    }

    var isAtEnd: Bool { offset >= end }

    private func need(_ count: Int) throws {
        guard count >= 0, offset + count <= end else { throw BaseCampDatabase.ReadError.damaged("BaseCamp") }
    }

    mutating func skip(_ count: Int) throws {
        try need(count)
        offset += count
    }

    mutating func u8() throws -> UInt8 {
        try need(1)
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u32() throws -> UInt32 {
        try need(4)
        defer { offset += 4 }
        return UInt32(bitPattern: BaseCampDatabase.int32(bytes, at: offset))
    }

    mutating func i32() throws -> Int32 {
        Int32(bitPattern: try u32())
    }

    /// A count of what follows, which cannot be more than the bytes left.
    mutating func count() throws -> Int {
        let value = Int(try i32())
        guard value >= 0, value <= end - offset else { throw BaseCampDatabase.ReadError.damaged("BaseCamp") }
        return value
    }

    mutating func f64() throws -> Double {
        try need(8)
        var bits: UInt64 = 0
        for index in 0..<8 {
            bits |= UInt64(bytes[offset + index]) << (8 * index)
        }
        offset += 8
        return Double(bitPattern: bits)
    }

    mutating func coordinate() throws -> Coordinate {
        let latitude = try i32()
        return BaseCampDatabase.semicircles(latitude, try i32())
    }

    mutating func stringBytes() throws -> [UInt8] {
        guard let nul = bytes[offset..<end].firstIndex(of: 0) else { throw BaseCampDatabase.ReadError.damaged("BaseCamp") }
        defer { offset = nul + 1 }
        return Array(bytes[offset..<nul])
    }

    mutating func string() throws -> String {
        String(decoding: try stringBytes(), as: UTF8.self)
    }

    /// A count, then that many strings.
    mutating func strings() throws -> [String] {
        try (0..<count()).map { _ in try string() }
    }

    /// A flag byte, then the value when the flag is 1.
    mutating func optional<Value>(_ read: (inout ByteReader) throws -> Value) throws -> Value? {
        switch try u8() {
        case 0: return nil
        case 1: return try read(&self)
        default: throw BaseCampDatabase.ReadError.damaged("BaseCamp")
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
