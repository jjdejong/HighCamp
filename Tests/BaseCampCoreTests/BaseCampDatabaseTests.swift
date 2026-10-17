@testable import BaseCampCore
import XCTest

/// BaseCamp's own library read with its lists and folders, from a small database written here in BaseCamp's layout.
final class BaseCampDatabaseTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("BaseCampDatabaseTests-\(UUID().uuidString)")
        let database = folder.appendingPathComponent("Database/4.8")
        try FileManager.default.createDirectory(at: database.appendingPathComponent("TrackSegments"), withIntermediateDirectories: true)
        try Data(Self.file("MsRcf", records: [Self.userWaypoint, Self.routePoint("A1", 10, at: Self.start),
                                               Self.routePoint("B1", 12, at: Self.end), Self.routePoint("1", 8, at: Self.start),
                                               Self.track, Self.route]))
            .write(to: database.appendingPathComponent("AllData.gdb"))
        try Data(Self.file("DifGf", records: Self.lists)).write(to: database.appendingPathComponent("FolderData.gfi"))
        try Data(Self.pointDetails).write(to: database.appendingPathComponent("TrackSegments/\(Self.trackFile)"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testTheDatabaseIsFoundInsideALibraryFolder() {
        XCTAssertEqual(BaseCampDatabase.databaseFolder(for: folder)?.lastPathComponent, "4.8")
        XCTAssertNil(BaseCampDatabase.databaseFolder(for: folder.appendingPathComponent("Database/4.8/TrackSegments")))
    }

    func testWaypointsComeWithTheirDetailsAndRoutePointsStayHidden() throws {
        let library = try read()
        XCTAssertEqual(library.waypoints.map(\.name), ["Col"])
        let col = try XCTUnwrap(library.waypoints.first)
        XCTAssertEqual(col.coordinate.latitude, 45.1, accuracy: 1e-6)
        XCTAssertEqual(col.elevation, 1326)
        XCTAssertEqual(col.symbol, "Campground")
        XCTAssertEqual(col.time, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(col.comment, "Aire de pique-nique\nhttps://example.org")
        XCTAssertEqual(col.address, WaypointAddress(street: "Route du Col", city: "Lans", state: "Isère", postalCode: "38250",
                                                    country: "France", phone: "+33 4 76 00 00 00"))
    }

    func testTracksKeepTheirColourAndTheHeightsAndTimesOfTheirFile() throws {
        let track = try XCTUnwrap(read().tracks.first)
        XCTAssertEqual(track.name, "Trace")
        XCTAssertEqual(track.color, GarminColour.color(named: "Red"))
        // Two blocks of two points that share one: three points.
        let points = try XCTUnwrap(track.segments.first)
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points.map(\.elevation), [200, 210, 220])
        XCTAssertEqual(points.last?.time, Date(timeIntervalSince1970: 1_600_000_002))
    }

    func testRoutesKeepTheirStopsAndBaseCampsLine() throws {
        let route = try XCTUnwrap(read().routes.first)
        XCTAssertEqual(route.name, "Boucle")
        // "1" is a waypoint too, but the longer name that fits is the route point's.
        XCTAssertEqual(route.stops.map(\.name), ["A1", "B1"])
        XCTAssertEqual(route.legs.count, 1)
        XCTAssertEqual(route.legs[0].method, .imported)
        let shape = route.legs[0].shape.map(\.coordinate)
        XCTAssertEqual(shape.count, 1)
        XCTAssertEqual(shape.first?.latitude ?? 0, Self.middle.latitude, accuracy: 1e-6)
        XCTAssertEqual(shape.first?.longitude ?? 0, Self.middle.longitude, accuracy: 1e-6)
    }

    func testListsAndFoldersAreKeptAndSmartListsLeftOut() throws {
        let library = try read()
        XCTAssertEqual(library.folders.map(\.name), ["Vercors"])
        XCTAssertEqual(library.collections.map(\.name), ["Balades"])
        let list = try XCTUnwrap(library.collections.first)
        XCTAssertEqual(list.folderID, library.folders.first?.id)
        XCTAssertEqual(list.items, [.waypoint(library.waypoints[0].id), .track(library.tracks[0].id), .route(library.routes[0].id)])
    }

    func testAListNamedAsOneAtTheTopIsNumbered() throws {
        var library = Library(collections: [LibraryCollection(name: "Balades")])
        var imported = try read()
        imported.collections[0].folderID = nil
        library.mergeWithLists(imported)
        XCTAssertEqual(library.collections.map(\.name), ["Balades", "Balades 2"])
        XCTAssertEqual(library.waypoints.count, 1)
    }

    /// The user's own BaseCamp library, when `BASECAMP_DB_PATH` names it.
    func testARealLibraryReadsWhole() throws {
        guard let path = ProcessInfo.processInfo.environment["BASECAMP_DB_PATH"] else {
            throw XCTSkip("Set BASECAMP_DB_PATH to a BaseCamp library to read it")
        }
        let database = try XCTUnwrap(BaseCampDatabase.databaseFolder(for: URL(fileURLWithPath: path)))
        let contents = try BaseCampDatabase.read(database)
        XCTAssertEqual(contents.unreadable, 0)
        XCTAssertFalse(contents.library.isEmpty)
        for route in contents.library.routes {
            XCTAssertEqual(route.legs.count, route.stops.count - 1, route.name)
        }
    }

    private func read() throws -> Library {
        try BaseCampDatabase.read(XCTUnwrap(BaseCampDatabase.databaseFolder(for: folder))).library
    }

    // MARK: A database in BaseCamp's layout

    private static let start = (45.2, 5.6)
    private static let middle = Coordinate(latitude: 45.25, longitude: 5.65)
    private static let end = (45.3, 5.7)
    private static let trackFile = "0A1B2C3D-0000-4000-8000-000000000001"

    private static var userWaypoint: (Character, Bytes) {
        var bytes = Bytes()
        bytes.string("Col")
        bytes.i32(0)
        bytes.point(45.1, 5.5)
        bytes.string("Aire de pique-nique")
        bytes.u8(0) // no proximity
        bytes.i32(1)
        bytes.i32(38) // Campground
        for text in ["Route du Col", "Lans", "Isère", "France", "38250"] { bytes.string(text) }
        bytes.u8(1)
        bytes.zeros(23)
        bytes.u8(0)
        bytes.optional(1326)
        bytes.optional(nil) // depth
        bytes.i32(1)
        bytes.string("https://example.org")
        bytes.optional(nil) // temperature
        bytes.u8(1)
        bytes.i32(1_700_000_100)
        bytes.zeros(6)
        bytes.i32(1)
        bytes.string("+33 4 76 00 00 00")
        bytes.u8(0)
        bytes.u8(1)
        bytes.i32(1_700_000_000)
        bytes.zeros(15)
        return ("W", bytes)
    }

    private static func routePoint(_ name: String, _ kind: Int32, at place: (Double, Double)) -> (Character, Bytes) {
        var bytes = Bytes()
        bytes.string(name)
        bytes.i32(kind)
        bytes.point(place.0, place.1)
        bytes.zeros(40)
        return ("W", bytes)
    }

    private static var track: (Character, Bytes) {
        var bytes = Bytes()
        bytes.string("Trace")
        bytes.i32(0)
        bytes.u8(1)
        bytes.i32(10) // Red
        bytes.i32(0) // no links
        bytes.string("")
        bytes.f64(1)
        bytes.u8(0)
        bytes.u8(0)
        bytes.zeros(16)
        bytes.u8(0)
        bytes.f64(2000)
        bytes.u8(0)
        bytes.i32(1) // one segment
        bytes.i32(2) // of two blocks
        for points in [[(45.0, 5.0), (45.01, 5.01)], [(45.01, 5.01), (45.02, 5.02)]] {
            bytes.u8(0)
            bytes.zeros(16)
            bytes.i32(Int32(points.count))
            for point in points { bytes.point(point.0, point.1) }
        }
        bytes.i32(3)
        bytes.string(trackFile)
        bytes.zeros(40)
        return ("T", bytes)
    }

    private static var pointDetails: [UInt8] {
        var bytes = Bytes()
        bytes.i32(3)
        for index in 0..<3 {
            bytes.optional(200 + 10 * Double(index))
            bytes.u8(1)
            bytes.i32(1_600_000_000 + Int32(index))
            bytes.zeros(15)
        }
        return header("MsRcf") + bytes.data
    }

    private static var route: (Character, Bytes) {
        var bytes = Bytes()
        bytes.string("Boucle")
        bytes.u8(0)
        bytes.i32(2)
        bytes.routePointHeader("A1", 10)
        bytes.pointList([start])
        bytes.zeros(20)
        bytes.pointList([start, (middle.latitude, middle.longitude), end])
        // What comes before a route point's name is not always a NUL.
        bytes.data += [0x40, 0x65, 0x15]
        bytes.routePointHeader("B1", 12)
        bytes.zeros(30)
        return ("R", bytes)
    }

    private static var lists: [(Character, Bytes)] {
        var top = Bytes()
        top.i32(-1)
        top.string("Ma Collection")
        top.i32(-1)
        top.i32(2)
        top.i32(1); top.i32(2) // folder 2
        top.i32(0); top.i32(0) // list 0
        var vercors = Bytes()
        vercors.i32(2)
        vercors.string("Vercors")
        vercors.i32(-1)
        vercors.i32(1)
        vercors.i32(0); vercors.i32(5)
        var smart = Bytes()
        smart.i32(0)
        smart.string("Semaine dernière")
        smart.i32(3)
        smart.i32(-1)
        smart.zeros(12)
        var balades = Bytes()
        balades.i32(5)
        balades.string("Balades")
        balades.i32(0)
        balades.i32(2)
        func member(_ name: String) -> Bytes {
            var bytes = Bytes()
            bytes.i32(5)
            bytes.string(name)
            bytes.zeros(4)
            return bytes
        }
        return [("F", top), ("F", vercors), ("I", smart), ("I", balades), ("W", member("Col")), ("T", member("Trace")),
                ("R", member("Boucle"))]
    }

    private static func header(_ magic: String) -> [UInt8] {
        var bytes = Bytes()
        bytes.data += Array(magic.utf8) + [0]
        bytes.record("D", [0x6D, 0])
        bytes.record("A", Array("build".utf8) + [0])
        bytes.string("BaseCamp")
        return bytes.data
    }

    private static func file(_ magic: String, records: [(Character, Bytes)]) -> [UInt8] {
        var bytes = Bytes()
        bytes.data = header(magic)
        for (type, payload) in records {
            bytes.record(type, payload.data)
        }
        return bytes.data
    }
}

private struct Bytes {
    var data: [UInt8] = []

    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func zeros(_ count: Int) { data += Array(repeating: 0, count: count) }
    mutating func i32(_ value: Int32) { data += withUnsafeBytes(of: value.littleEndian, Array.init) }
    mutating func f64(_ value: Double) { data += withUnsafeBytes(of: value.bitPattern.littleEndian, Array.init) }
    mutating func string(_ text: String) { data += Array(text.utf8) + [0] }

    mutating func optional(_ value: Double?) {
        if let value {
            u8(1)
            f64(value)
        } else {
            u8(0)
        }
    }

    mutating func point(_ latitude: Double, _ longitude: Double) {
        i32(Self.semicircles(latitude))
        i32(Self.semicircles(longitude))
    }

    mutating func record(_ type: Character, _ payload: [UInt8]) {
        i32(Int32(payload.count))
        u8(type.asciiValue!)
        data += payload
    }

    mutating func routePointHeader(_ name: String, _ kind: Int32) {
        string(name)
        i32(kind)
        data += [0, 3, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF]
        zeros(10)
    }

    /// A count, the points, a zero byte and the box round them.
    mutating func pointList(_ points: [(Double, Double)]) {
        i32(Int32(points.count))
        for point in points { self.point(point.0, point.1) }
        u8(0)
        let latitudes = points.map { Self.semicircles($0.0) }, longitudes = points.map { Self.semicircles($0.1) }
        i32(latitudes.max()!); i32(longitudes.max()!); i32(latitudes.min()!); i32(longitudes.min()!)
    }

    static func semicircles(_ degrees: Double) -> Int32 {
        Int32((degrees * 2_147_483_648 / 180).rounded())
    }
}
