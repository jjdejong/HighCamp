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

        // Saved again, it is the current version and reads back the same.
        try LibraryFile.save(stored.library, to: url)
        let again = try LibraryFile.read(from: url)
        XCTAssertEqual(again.version, LibraryFile.currentVersion)
        XCTAssertEqual(again.library, stored.library)
    }

    // MARK: Lines kept apart

    /// A track with every kind of point value, and a route whose legs have shapes, one with a named point.
    private func linedLibrary() -> Library {
        let track = Track(name: "Ride", segments: [
            [
                TrackPoint(coordinate: Coordinate(latitude: 45.123456789, longitude: 6.987654321), elevation: 812.25,
                           time: Date(timeIntervalSinceReferenceDate: 700_000_000.123), heartRate: 140, cadence: 85,
                           power: 210.5, temperature: 18.5),
                TrackPoint(coordinate: Coordinate(latitude: 45.2, longitude: 7)),
            ],
            [TrackPoint(coordinate: Coordinate(latitude: 45.3, longitude: 7.1), temperature: -2)],
        ], color: ItemColor(red: 1, green: 0, blue: 0))
        let route = Route(name: "Loop", stops: [
            RouteStop(name: "A", coordinate: Coordinate(latitude: 45, longitude: 6)),
            RouteStop(coordinate: Coordinate(latitude: 45.1, longitude: 6.1)),
            RouteStop(name: "C", coordinate: Coordinate(latitude: 45.2, longitude: 6.2)),
        ], legs: [
            RouteLeg(shape: [RoutePoint(coordinate: Coordinate(latitude: 45.05, longitude: 6.05), elevation: 500),
                             RoutePoint(name: "Col", coordinate: Coordinate(latitude: 45.07, longitude: 6.07))],
                     method: .imported),
            RouteLeg(),
        ])
        return Library(routes: [route], tracks: [track])
    }

    private func lineFiles(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: LibraryFile.linesFolder(for: url).path)) ?? []).sorted()
    }

    func testTrackPointsAndRouteShapesAreKeptApartAndReadBack() throws {
        let url = directory.appendingPathComponent("Library.json")
        let original = linedLibrary()

        try LibraryFile.save(original, to: url)

        XCTAssertEqual(LibraryFile.linesFolder(for: url).lastPathComponent, "Library Lines")
        XCTAssertEqual(lineFiles(url).count, 2)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("45.123456789"))
        XCTAssertFalse(text.contains("45.07"))
        XCTAssertTrue(text.contains("45.1"), "stops stay in the library file")
        let stored = try LibraryFile.read(from: url)
        XCTAssertEqual(stored.version, 3)
        XCTAssertEqual(stored.library, original)
    }

    func testAVersion2FileWithInlineLinesIsReadAndSavedApart() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Library.json")
        let original = linedLibrary()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let library = String(decoding: try encoder.encode(original), as: UTF8.self)
        try Data(#"{"version": 2, "library": \#(library)}"#.utf8).write(to: url)

        let old = try LibraryFile.read(from: url)
        XCTAssertEqual(old.version, 2)
        XCTAssertEqual(old.library.tracks.first?.segments.count, 2)
        XCTAssertEqual(old.library.routes.first?.legs.first?.shape.count, 2)

        try LibraryFile.save(old.library, to: url)
        XCTAssertEqual(lineFiles(url).count, 2)
        XCTAssertEqual(try LibraryFile.load(from: url), old.library)
    }

    func testOnlyChangedLinesAreWrittenAndUnusedOnesRemoved() throws {
        let url = directory.appendingPathComponent("Library.json")
        var library = linedLibrary()
        var written = LibraryFile.LinesWritten()
        try LibraryFile.save(library, to: url, written: &written)
        let before = lineFiles(url)
        let routeFile = try XCTUnwrap(before.first { $0.hasPrefix(library.routes[0].id.uuidString) })
        let routeDate = try FileManager.default.attributesOfItem(
            atPath: LibraryFile.linesFolder(for: url).appendingPathComponent(routeFile).path)[.modificationDate] as? Date

        library.tracks[0].segments[0][1].elevation = 900
        try LibraryFile.save(library, to: url, written: &written)

        let after = lineFiles(url)
        XCTAssertEqual(after.count, 2)
        XCTAssertTrue(after.contains(routeFile))
        XCTAssertEqual(Set(after).subtracting(before).count, 1, "the track has a new file, the old one is gone")
        XCTAssertEqual(try FileManager.default.attributesOfItem(
            atPath: LibraryFile.linesFolder(for: url).appendingPathComponent(routeFile).path)[.modificationDate] as? Date,
            routeDate)
        XCTAssertEqual(try LibraryFile.load(from: url), library)

        library.tracks.removeAll()
        try LibraryFile.save(library, to: url, written: &written)
        XCTAssertEqual(lineFiles(url), [routeFile])
        XCTAssertEqual(try LibraryFile.load(from: url), library)
    }

    func testItemsWithoutLinesHaveNoFile() throws {
        let url = directory.appendingPathComponent("Library.json")
        let library = Library(
            routes: [Route(name: "Straight", stops: [RouteStop(coordinate: Coordinate(latitude: 45, longitude: 6)),
                                                     RouteStop(coordinate: Coordinate(latitude: 46, longitude: 6))])],
            tracks: [Track(name: "Empty")]
        )

        try LibraryFile.save(library, to: url)

        XCTAssertEqual(lineFiles(url), [])
        XCTAssertEqual(try LibraryFile.load(from: url), library)
    }

    func testAMissingOrDamagedLineFileFailsTheRead() throws {
        let url = directory.appendingPathComponent("Library.json")
        try LibraryFile.save(linedLibrary(), to: url)
        let folder = LibraryFile.linesFolder(for: url)
        let names = lineFiles(url)

        try Data("HCLN".utf8).write(to: folder.appendingPathComponent(names[0]))
        XCTAssertThrowsError(try LibraryFile.load(from: url)) { error in
            XCTAssertEqual(error as? LibraryFileError, .damagedLines(names[0]))
        }

        try FileManager.default.removeItem(at: folder.appendingPathComponent(names[0]))
        XCTAssertThrowsError(try LibraryFile.load(from: url)) { error in
            XCTAssertEqual(error as? LibraryFileError, .damagedLines(names[0]))
        }
    }

    func testMoveAndCopyKeepTheLinesWithTheFile() throws {
        let url = directory.appendingPathComponent("Library.json")
        let library = linedLibrary()
        try LibraryFile.save(library, to: url)

        let moved = directory.appendingPathComponent("Library-unreadable-1.json")
        try LibraryFile.move(url, to: moved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: LibraryFile.linesFolder(for: url).path))
        XCTAssertEqual(try LibraryFile.load(from: moved), library)

        let backup = directory.appendingPathComponent("Backups/Library-1")
        try LibraryFile.copy(moved, into: backup)
        XCTAssertEqual(try LibraryFile.load(from: backup.appendingPathComponent(moved.lastPathComponent)), library)
        XCTAssertEqual(try LibraryFile.load(from: moved), library)
    }

    func testDamagedLineDataIsRejectedNotTrusted() {
        let data = LibraryLines.track([[TrackPoint(coordinate: Coordinate(latitude: 1, longitude: 2), elevation: 3)]]).encoded()

        XCTAssertNoThrow(try LibraryLines(data))
        for cut in [0, 5, 10, data.count - 1] {
            XCTAssertThrowsError(try LibraryLines(data.prefix(cut)))
        }
        var huge = data
        huge.replaceSubrange(6..<10, with: [0xff, 0xff, 0xff, 0x7f])
        XCTAssertThrowsError(try LibraryLines(huge))
        XCTAssertThrowsError(try LibraryLines(data + Data([0])))
    }
}
