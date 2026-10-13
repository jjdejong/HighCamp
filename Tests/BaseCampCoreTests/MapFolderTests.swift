import XCTest
@testable import BaseCampCore

final class MapFolderTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MapFolderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testListsImgMapsOnly() throws {
        try Data(repeating: 0, count: 10).write(to: folder.appendingPathComponent("zeta.img"))
        try Data(repeating: 0, count: 3).write(to: folder.appendingPathComponent("Alpha.IMG"))
        try Data().write(to: folder.appendingPathComponent("notes.txt"))
        try Data().write(to: folder.appendingPathComponent(".hidden.img"))
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("folder.img"),
            withIntermediateDirectories: true
        )

        let maps = try MapFolder.imgMaps(in: folder)

        XCTAssertEqual(maps.map(\.name), ["Alpha.IMG", "zeta.img"])
        XCTAssertEqual(maps.map(\.size), [3, 10])
    }

    func testEmptyFolderHasNoMaps() throws {
        XCTAssertEqual(try MapFolder.imgMaps(in: folder), [])
    }

    func testMissingFolderThrows() {
        XCTAssertThrowsError(try MapFolder.imgMaps(in: folder.appendingPathComponent("absent")))
    }
}
