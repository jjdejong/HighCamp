import XCTest
@testable import BaseCampCore

final class LibraryFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryFileTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func sampleLibrary() -> Library {
        Library(
            waypoints: [Waypoint(
                name: "Camp",
                coordinate: Coordinate(latitude: 45.5, longitude: 6.25),
                elevation: 1200,
                time: Date(timeIntervalSince1970: 1_700_000_000.5),
                comment: "Water",
                symbol: "Flag"
            )],
            routes: [Route(name: "Loop", points: [
                RoutePoint(name: "A", coordinate: Coordinate(latitude: 45, longitude: 6)),
            ])],
            tracks: [Track(name: "Ride", segments: [[
                TrackPoint(coordinate: Coordinate(latitude: 45.1, longitude: 6.1), elevation: 800, time: Date(timeIntervalSince1970: 1_700_000_100)),
            ]])]
        )
    }

    func testSaveAndLoadKeepsEverything() throws {
        let url = directory.appendingPathComponent("Library.json")
        let original = sampleLibrary()

        try LibraryFile.save(original, to: url)
        let loaded = try LibraryFile.load(from: url)

        XCTAssertEqual(loaded, original)
    }

    func testSaveCreatesMissingFolders() throws {
        let url = directory.appendingPathComponent("nested/Library.json")

        try LibraryFile.save(Library(), to: url)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testLoadingAMissingFileFails() {
        let url = directory.appendingPathComponent("missing.json")

        XCTAssertThrowsError(try LibraryFile.load(from: url))
    }

    func testRejectsAnUnknownFormatVersion() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Future.json")
        try Data(#"{"version": 99, "library": {"waypoints": [], "routes": [], "tracks": []}}"#.utf8).write(to: url)

        XCTAssertThrowsError(try LibraryFile.load(from: url)) { error in
            XCTAssertEqual(error as? LibraryFileError, .unsupportedVersion(99))
        }
    }

    func testReadsAVersion1FileWithRoutesAsPoints() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Old.json")
        let id = UUID()
        let json = """
        {"version": 1, "library": {"waypoints": [], "tracks": [], "routes": [{"id": "\(id.uuidString)", "name": "Old",
         "points": [{"coordinate": {"latitude": 45, "longitude": 6}, "name": "A", "elevation": 300},
                    {"coordinate": {"latitude": 45.01, "longitude": 6}}]}]}}
        """
        try Data(json.utf8).write(to: url)

        let stored = try LibraryFile.read(from: url)

        XCTAssertEqual(stored.version, 1)
        let route = try XCTUnwrap(stored.library.routes.first)
        XCTAssertEqual(route.id, id)
        XCTAssertEqual(route.stops.map(\.name), ["A", nil])
        XCTAssertEqual(route.stops.first?.elevation, 300)
        XCTAssertEqual(route.legs, [RouteLeg()])

        // Saved again, it is version 2 and reads back the same.
        try LibraryFile.save(stored.library, to: url)
        let again = try LibraryFile.read(from: url)
        XCTAssertEqual(again.version, 2)
        XCTAssertEqual(again.library, stored.library)
    }
}
