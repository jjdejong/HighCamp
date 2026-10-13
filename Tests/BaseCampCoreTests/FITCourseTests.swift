import XCTest
@testable import BaseCampCore

final class FITCourseTests: XCTestCase {
    private let samplePoints = [
        CoursePoint(coordinate: Coordinate(latitude: 45.0, longitude: 5.0), elevation: 300),
        CoursePoint(coordinate: Coordinate(latitude: 45.001, longitude: 5.0005), elevation: 302),
        CoursePoint(coordinate: Coordinate(latitude: 45.002, longitude: 5.001), elevation: nil),
    ]

    func testCRCMatchesStandardCheckValue() {
        // CRC-16/ARC check value for the ASCII digits "123456789".
        XCTAssertEqual(FITChecksum.crc16(Array("123456789".utf8)), 0xBB3D)
    }

    func testFileHeaderDescribesTheFile() throws {
        let data = try FITCourse.encode(name: "Test course", points: samplePoints)
        let bytes = [UInt8](data)

        XCTAssertEqual(bytes[0], 14, "header size")
        XCTAssertEqual(bytes[1], 0x20, "protocol 2.0")
        XCTAssertEqual(Array(bytes[8..<12]), Array(".FIT".utf8))

        let dataSize = UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24
        XCTAssertEqual(Int(dataSize), bytes.count - 14 - 2, "data size excludes header and trailing CRC")
    }

    func testChecksumsAreCorrect() throws {
        let data = try FITCourse.encode(name: "Test course", points: samplePoints)
        let bytes = [UInt8](data)

        let headerCRC = UInt16(bytes[12]) | UInt16(bytes[13]) << 8
        XCTAssertEqual(headerCRC, FITChecksum.crc16(bytes[0..<12]))

        let fileCRC = UInt16(bytes[bytes.count - 2]) | UInt16(bytes[bytes.count - 1]) << 8
        XCTAssertEqual(fileCRC, FITChecksum.crc16(bytes[0..<(bytes.count - 2)]))
    }

    func testCourseNameIsStoredAsText() throws {
        let data = try FITCourse.encode(name: "Col du Galibier", points: samplePoints)

        XCTAssertNotNil(data.range(of: Data("Col du Galibier".utf8)))
    }

    func testNameIsTruncatedToDeviceLimit() {
        let long = String(repeating: "A", count: 80)

        XCTAssertEqual(FITCourse.truncatedName(long).utf8.count, FITCourse.maxNameBytes)
    }

    func testTruncationKeepsWholeCharacters() {
        // "é" is two bytes in UTF-8. The cut must not split a character.
        let name = String(repeating: "é", count: 40)
        let truncated = FITCourse.truncatedName(name)

        XCTAssertLessThanOrEqual(truncated.utf8.count, FITCourse.maxNameBytes)
        XCTAssertEqual(truncated, String(repeating: "é", count: 24))
    }

    func testEmptyNameFallsBackToDefault() {
        XCTAssertEqual(FITCourse.truncatedName("   "), "Course")
    }

    func testFileNameIsSafeForTheDevice() {
        XCTAssertEqual(FITCourse.fileName(for: "Lac du Bourget / J2"), "Lac_du_Bourget___J2.fit")
        XCTAssertEqual(FITCourse.fileName(for: ""), "Course.fit")
    }

    func testTooFewPointsIsAnError() {
        XCTAssertThrowsError(try FITCourse.encode(name: "One", points: [samplePoints[0]])) { error in
            XCTAssertEqual(error as? FITCourseError, .tooFewPoints)
        }
    }

    func testRouteAndTrackBecomeCoursePoints() {
        let route = Route(name: "R", points: [
            RoutePoint(coordinate: Coordinate(latitude: 1, longitude: 2)),
            RoutePoint(coordinate: Coordinate(latitude: 3, longitude: 4)),
        ])
        let track = Track(name: "T", segments: [
            [TrackPoint(coordinate: Coordinate(latitude: 5, longitude: 6), elevation: 100)],
            [TrackPoint(coordinate: Coordinate(latitude: 7, longitude: 8))],
        ])

        XCTAssertEqual(route.coursePoints.count, 2)
        XCTAssertNil(route.coursePoints[0].elevation)
        XCTAssertEqual(track.coursePoints.count, 2)
        XCTAssertEqual(track.coursePoints[0].elevation, 100)
    }

    /// Writes a sample course for checking with Garmin's decoder.
    /// Runs only when FIT_DUMP_PATH is set, for example:
    ///   FIT_DUMP_PATH=/tmp/sample.fit swift test --filter FITCourseTests
    func testDumpSampleForExternalCheck() throws {
        guard let path = ProcessInfo.processInfo.environment["FIT_DUMP_PATH"] else {
            throw XCTSkip("set FIT_DUMP_PATH to write a sample file")
        }
        let points = (0..<12).map { index in
            CoursePoint(
                coordinate: Coordinate(latitude: 45.0 + Double(index) * 0.0008, longitude: 5.0 + Double(index) * 0.0004),
                elevation: 300 + Double(index) * 2
            )
        }
        let data = try FITCourse.encode(name: "BCCLONE_SAMPLE", points: points, startTime: Date(timeIntervalSince1970: 1_700_000_000))
        try data.write(to: URL(fileURLWithPath: path))
    }
}
